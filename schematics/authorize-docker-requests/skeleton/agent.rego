package docker.authz

# ─── OPA authorization policy for restricted Docker sandbox access ──
#
# This file is a TEMPLATE: the PLACEHOLDER tokens below must be replaced with
# values from the Parameters table in SCHEMATIC.md before it is deployed, and
# no placeholder may remain in the deployed copy (the policy would silently
# treat every sandbox client as a host client and allow everything — see the
# deployment phase and its acceptance test).
#
#   SANDBOX_USERNAME           → P-4 (client certificate CN), e.g. "sandbox-agent"
#   AUTH_HEADER_NAME           → P-9 header name, e.g. "X-Sandbox-Agent"
#   PROJECT_NAME               → P-3 compose project name, e.g. "backend-services"
#   PROJECT_DIR_PATH           → P-15 host directory holding the project, e.g.
#                                "/srv/compose/backend-services"
#   TESTCONTAINERS_LABEL_KEY   → P-12 label key, e.g. "org.testcontainers"
#   TESTCONTAINERS_LABEL_VALUE → P-12 label value, e.g. "true"
#   EXTRA_BIND_ROOTS           → P-16 extra accepted bind roots, as a
#                                comma-separated list of absolute directories,
#                                e.g. "/srv/media,/srv/downloads"; empty when
#                                the project directory is the only boundary
#
# (P-11 BUILDKIT_PREFIX is not read by any rule — see SCHEMATIC.md's Decisions.
# The leftover-token check in the package still greps for it, so a copy carrying
# the token is caught rather than deployed.)
#
# Language and engine: Rego v1 syntax, evaluated by the OPA engine embedded in
# the plugin. The plugin release determines the engine (see P-10), measured from
# the plugin's own go.mod at each tag: v0.10 embeds OPA v1.3.0, v0.9 embeds OPA
# v0.60.0 — this file loads and decides identically on both, and on 1.7.1.
# Older releases (v0.8, OPA v0.30) reject `import rego.v1`. Validate a change
# with an engine no newer than the plugin's:
#
#   opa check agent.rego
#   opa eval -f raw --data agent.rego --input probe.json data.docker.authz.allow
#
# The policy has two jobs, and the second one is the reason it exists: restrict
# a sandbox client to its own compose project (R-5, R-12, R-18), and refuse any
# request in that project's name that would reach the host (R-15, R-16). Every
# create path passes `safe_container_config`; see the probe table in
# agent.rego.schema for the requests this is asserted against.
#
# Paths are matched against `path`, not against the plugin's raw PathPlain
# field: the plugin sets PathPlain to the *raw request path*, API version
# prefix and all ("PathPlain": u.Path, main.go), so a policy keyed on the raw
# field decides nothing on a live daemon. See the derivation below.

import rego.v1

default allow := false

# ─── Identity detection ──────────────────────────────────────────
# The plugin sets input.User to the TLS client certificate's subject common
# name; it is empty for unix-socket requests and for TCP clients without a
# certificate.
is_sandbox if {
	input.User == "SANDBOX_USERNAME"
}

# The header is the secondary signal. Docker's authorization request carries
# headers as `map[string]string`, so the value is a string and only a string is
# compared here.
is_sandbox if {
	input.Headers["AUTH_HEADER_NAME"] == "true"
}

# ─── Host users (unix socket) — unrestricted ─────────────────────
allow if {
	not is_sandbox
}

# ─── Sandbox default ─────────────────────────────────────────────
default allow_sandbox := false

# ─── Path handling ───────────────────────────────────────────────
# The plugin builds the input from the raw request URL: `"PathPlain": u.Path`
# and `"PathArr": strings.Split(u.Path, "/")` (main.go, makeInput). Nothing
# strips the API version prefix — `-skip-ping` only bypasses `HEAD /_ping` —
# so on a live daemon PathPlain is `/v1.56/containers/create`, not
# `/containers/create`, and PathArr is `["", "v1.56", "containers", "create"]`.
#
# Every rule below therefore matches `path`: PathPlain with one optional
# version segment removed. The strip is anchored and single, and a request
# that carries no version is left alone, so all of these behave as the API
# says they should:
#
#   /v1.56/containers/create  → /containers/create
#   /containers/create        → /containers/create   (client sends no version)
#   /v1/containers/create     → /containers/create   (major only)
#   /_ping                    → /_ping               (nothing to strip)
#   /v1.56/v1.56/x            → /v1.56/x             (one strip, still no grant)
#
# `path_segments` is the same path split on "/", so a resource named in the
# path is matched as a whole segment and neither the version segment nor a
# query string can satisfy a match.
#
# A path with a `..` segment yields no `path` at all, so no rule can match it:
# the daemon cleans the path before routing, and the plugin authorizes the raw
# one, so nothing in this policy should be reachable through a traversal.
path := p if {
	p := regex.replace(object.get(input, "PathPlain", ""), "^/v[0-9]+(\\.[0-9]+)?", "")
	not traversal(p)
}

path_segments := split(path, "/")

# ─── Read-only operations ────────────────────────────────────────
allow_sandbox if {
	is_sandbox
	input.Method in {"GET", "HEAD"}
}

# ─── Image builds ────────────────────────────────────────────────
# `/build` exactly: equality, not `contains`, so that no neighbouring endpoint
# (/build/prune) and no path that merely contains the string is granted.
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	path == "/build"
}

# `/session` is the CLI's BuildKit session endpoint: the daemon's built-in
# builder asks the client for build inputs over it, so a build on a
# BuildKit-enabled daemon (the default) needs it. It is granted for the same
# reason `/build` is: the client runs the build, and the session serves data
# the client already holds. Without it, R-7's build test fails on a default
# daemon — see SCHEMATIC.md's Decisions.
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	path == "/session"
}

# ─── Image pulls ─────────────────────────────────────────────────
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	path == "/images/create"
}

# ─── Container create — the project's label and a safe config ────
# Equality on the version-free path matters twice: the daemon forwards a JSON
# body to the plugin for *any* endpoint whose content type is JSON, and the
# attach/exec handlers ignore fields they do not know — so a rule matching a
# path prefix could be satisfied by POST /containers/<id>/attach with a crafted
# body.
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	path == "/containers/create"
	project_container
	safe_container_config
}

# ─── Testcontainers containers (integration tests) ────────────────
# No compose label, so the label is the identity here; the same R-15 gate
# applies, which means a test container may only mount paths inside P-15.
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	path == "/containers/create"
	testcontainers_container
	safe_container_config
}

testcontainers_container if {
	input.Body.Labels["TESTCONTAINERS_LABEL_KEY"] == "TESTCONTAINERS_LABEL_VALUE"
}

# ─── R-15: refuse a container that could reach the host ──────────
# This is the gate every create path passes. It rejects, in order: a privileged
# container, added capabilities, host devices, a relaxed security profile,
# inherited volumes, a host or joined namespace, an explicit userns mode, and
# any mount whose source is not a volume name or a path inside the project
# directory.
safe_container_config if {
	not host_access_config
	not unsafe_bind
	not legacy_volume_driver
}

# The legacy `Binds` route selects its driver here rather than per mount: a
# `Binds` source that is not an absolute path is a volume name, and the daemon
# creates that volume with this driver. Only the local driver, or none, is
# accepted — the same choice `volume_driver_ok` makes for a volume create's own
# `Driver`, and for the same reason: another driver's volume is one this policy
# cannot see the contents of.
legacy_volume_driver if {
	driver := object.get(host_config, "VolumeDriver", "")
	is_string(driver)
	driver != ""
	driver != "local"
}

host_access_config if {
	host_config.Privileged == true
}

host_access_config if {
	count(object.get(host_config, "CapAdd", [])) > 0
}

host_access_config if {
	count(object.get(host_config, "Devices", [])) > 0
}

host_access_config if {
	count(object.get(host_config, "SecurityOpt", [])) > 0
}

# `--volumes-from` copies another container's mounts — including whatever host
# paths that container holds — into this one.
host_access_config if {
	count(object.get(host_config, "VolumesFrom", [])) > 0
}

host_access_config if {
	host_namespace_mode(host_config.PidMode)
}

host_access_config if {
	host_namespace_mode(host_config.IpcMode)
}

host_access_config if {
	host_namespace_mode(host_config.NetworkMode)
}

host_access_config if {
	host_namespace_mode(host_config.CgroupnsMode)
}

host_access_config if {
	host_config.UsernsMode == "host"
}

# A namespace is granted either by joining the host's or by joining another
# container's: `container:<id>` on a host-networked container is the host's
# network, one hop away. Deliberate extension of R-15's list; see the probe
# table. It does mean a compose `network_mode: service:<name>` is refused.
host_namespace_mode(mode) if {
	is_string(mode)
	mode == "host"
}

host_namespace_mode(mode) if {
	is_string(mode)
	startswith(mode, "container:")
}

# ─── R-15: mounts ────────────────────────────────────────────────
unsafe_bind if {
	some m in object.get(host_config, "Binds", [])
	not bind_ok(split(m, ":")[0])
}

unsafe_bind if {
	some m in object.get(host_config, "Mounts", [])
	not mount_ok(m)
}

# The plugin's own enrichment: `Resolved` is the source with symlinks resolved,
# so it is the field that catches a link inside the project directory pointing
# outside it. It is empty when the plugin cannot read the host path (a
# managed-plugin install), in which case the raw source is what gets checked.
unsafe_bind if {
	some bm in object.get(input, ["BindMounts"], [])
	not bindmount_ok(bm)
}

bindmount_ok(bm) if {
	is_string(bm.Resolved)
	bm.Resolved != ""
	bind_ok(bm.Resolved)
}

bindmount_ok(bm) if {
	not resolved_source(bm)
	bind_ok(bm.Source)
}

resolved_source(bm) if {
	r := object.get(bm, "Resolved", "")
	is_string(r)
	r != ""
}

# A named or anonymous volume: Docker treats a source that is not an absolute
# path as a volume name. Volume *creation* is what R-16 constrains, so a
# project volume mounted here is the legitimate case this must not refuse.
bind_ok(src) if {
	is_string(src)
	not startswith(src, "/")
}

# A host path inside the project directory, with no traversal segment: a source
# of "/srv/compose/backend-services/../../etc" starts with the project
# directory but is not inside it.
bind_ok(src) if {
	is_string(src)
	in_project_path(src)
}

# A host path inside one of the deployment's accepted extra roots (P-16), with no
# traversal segment. A root is a prefix grant, so it is matched as a directory
# path or as a whole path, never as a substring, and a root of "/" is dropped
# rather than accepted: naming it would make this gate decorative.
bind_ok(src) if {
	is_string(src)
	in_extra_root(src)
}

in_project_path(p) if {
	not traversal(p)
	project_dir == p
}

in_project_path(p) if {
	not traversal(p)
	startswith(p, concat("", [project_dir, "/"]))
}

# A root matched exactly: this is how a single file is named (a known_hosts, a
# socket), without granting the directory that holds it.
in_extra_root(p) if {
	not traversal(p)
	some root in extra_roots
	root == p
}

in_extra_root(p) if {
	not traversal(p)
	some root in extra_roots
	startswith(p, concat("", [root, "/"]))
}

# P-16 as a list: absolute directories this deployment accepts as bind sources
# beyond the project directory, comma-separated in the template. A trailing "/"
# or "/**" is accepted and means the directory itself. An empty value — the
# default, and what an unsubstituted token leaves behind — yields no root, so
# the project directory stays the only boundary.
extra_roots := [root |
	some entry in split("EXTRA_BIND_ROOTS", ",")
	root := trim_suffix(trim_suffix(trim_space(entry), "/"), "/**")
	root != "/"
	startswith(root, "/")
]

traversal(p) if {
	some segment in split(p, "/")
	segment == ".."
}

project_dir := trim_suffix("PROJECT_DIR_PATH", "/")

mount_ok(m) if {
	m.Type == "volume"
	not volume_driver_options(m)
	volume_driver_local(m)
}

# `VolumeOptions.DriverConfig.Options` on a container's *own* mount is the same
# capability R-16 refuses at the volume-create endpoint, one door along: the
# daemon passes those options to the volume's driver when it creates the named
# volume (a fresh name carries them), and the local driver's `type: none`,
# `o: bind`, `device: /` then performs that bind when the container mounts the
# volume. Any non-empty option object is refused, rather than accepting the
# options a bind needs: the option set the local driver honours is not a list
# this gate should be maintaining a copy of. Presence tests are `object.get`
# chains, for the reason R-16's `volume_driver_ok` records — a builtin on a
# missing field fails the rule instead of falling through.
volume_driver_options(m) if {
	driver := object.get(object.get(m, "VolumeOptions", {}), "DriverConfig", {})
	options := object.get(driver, "Options", {})
	is_object(options)
	count(options) > 0
}

# Only the local driver, or none at all: a mount that names another driver asks
# for a volume whose contents this policy cannot see, which is not a volume this
# gate can call safe.
volume_driver_local(m) if {
	driver := object.get(object.get(m, "VolumeOptions", {}), "DriverConfig", {})
	name := object.get(driver, "Name", "")
	name in {"", "local"}
}

mount_ok(m) if {
	m.Type == "tmpfs"
}

mount_ok(m) if {
	m.Type == "bind"
	bind_ok(m.Source)
}

# An entry with no type is treated as a bind: its source decides.
mount_ok(m) if {
	not is_string(object.get(m, "Type", null))
	bind_ok(m.Source)
}

host_config := object.get(input, ["Body", "HostConfig"], {})

# ─── Container lifecycle actions (closed allowlist) ──────────────
# Any container id: the authorization request for an operation on an existing
# container carries no body and names its target only by id, so no policy at
# this interface can attribute it to a project (see SCHEMATIC.md's
# Limitations).
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	startswith(path, "/containers/")
	lifecycle_action
}

lifecycle_action if {
	some action in {
		"start", "stop", "restart", "kill",
		"pause", "unpause", "wait", "update",
	}
	endswith(path, sprintf("/%s", [action]))
}

# ─── Container delete (documented limitation, see Limitations) ───
allow_sandbox if {
	is_sandbox
	input.Method == "DELETE"
	startswith(path, "/containers/")
}

# ─── Network and volume creation ─────────────────────────────────
# Creation is project-scoped through the resource name in the request body
# (compose names its networks and volumes "<project>_<suffix>"). A volume
# create additionally passes R-16: a project-named volume must not be a
# disguised host mount.
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	path == "/networks/create"
	project_named_body
}

allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	path == "/volumes/create"
	project_named_body
	safe_volume_create
}

# ─── R-16: a volume create may not carry driver options ──────────
# `DriverOpts: {type: none, o: bind, device: /}` turns a project-named volume
# into the host filesystem; a project container then mounts it. Only the local
# driver with no options is accepted.
safe_volume_create if {
	not volume_driver_opts
	volume_driver_ok
}

volume_driver_opts if {
	opts := object.get(input.Body, "DriverOpts", {})
	is_object(opts)
	count(opts) > 0
}

volume_driver_ok if {
	# object.get, not `not is_string(...)`: a builtin call on a missing field
	# makes the whole rule fail rather than fall through, so the absent-driver
	# case would have been denied. A missing driver means the default (`local`).
	object.get(input.Body, "Driver", "local") in {"", "local"}
}

# ─── Path-named network and volume operations ────────────────────
# Attach/detach and other in-place operations name the resource in the path, so
# the project is matched as a whole path segment.
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	startswith(path, "/networks/")
	project_path_resource
}

allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	startswith(path, "/volumes/")
	project_path_resource
}

# ─── R-18: deletes are scoped the same way ───────────────────────
# `docker compose down` deletes its own network and volumes by name, and a
# delete names the resource in the path, so the same whole-segment match
# applies. A delete by opaque id does not match and is refused; container
# deletes stay unscoped above, because their request carries nothing at all.
allow_sandbox if {
	is_sandbox
	input.Method == "DELETE"
	startswith(path, "/networks/")
	project_path_resource
}

allow_sandbox if {
	is_sandbox
	input.Method == "DELETE"
	startswith(path, "/volumes/")
	project_path_resource
}

# ─── Project resource detection ──────────────────────────────────
project_container if {
	input.Body.Labels["com.docker.compose.project"] == "PROJECT_NAME"
}

project_named_body if {
	input.Body.Name == "PROJECT_NAME"
}

project_named_body if {
	startswith(input.Body.Name, "PROJECT_NAME_")
}

# A resource named in the path is matched as a whole segment of the derived
# path rather than as a substring of it, which also means neither the version
# segment nor a query string can satisfy the match.
project_path_resource if {
	some segment in path_segments
	segment == "PROJECT_NAME"
}

project_path_resource if {
	some segment in path_segments
	startswith(segment, "PROJECT_NAME_")
}

# ─── Final decision ──────────────────────────────────────────────
allow if {
	is_sandbox
	allow_sandbox
}
