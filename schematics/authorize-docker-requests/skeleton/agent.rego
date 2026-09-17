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
#   BUILDKIT_PREFIX            → P-11, e.g. "/buildx_buildkit_"
#   TESTCONTAINERS_LABEL_KEY   → P-12 label key, e.g. "org.testcontainers"
#   TESTCONTAINERS_LABEL_VALUE → P-12 label value, e.g. "true"
#
# Language and engine: Rego v1 syntax, evaluated by the OPA engine embedded in
# the plugin. The plugin release determines the engine (see P-10): v0.10 embeds
# OPA v1.7.1 and v0.9 embeds OPA v0.60.0 — both load and evaluate this file
# identically (verified). Older releases (v0.8, OPA v0.30) reject `import
# rego.v1`. Validate a change with an engine no newer than the plugin's:
#
#   opa check agent.rego
#   opa eval --data agent.rego --input probe.json data.docker.authz.allow

import rego.v1

default allow := false

# ─── Identity detection ──────────────────────────────────────────
# The plugin sets input.User to the TLS client certificate's subject common
# name; it is empty for unix-socket requests and for TCP clients without a
# certificate.
is_sandbox if {
	input.User == "SANDBOX_USERNAME"
}

# The header is the secondary signal. Its value arrives as a plain string in the
# plugin's own input document; a one-element list is also accepted, because the
# shape is the plugin's to choose and a mismatch here would silently drop the
# second signal rather than fail loudly.
is_sandbox if {
	header_says_sandbox
}

header_says_sandbox if {
	input.Headers["AUTH_HEADER_NAME"] == "true"
}

header_says_sandbox if {
	input.Headers["AUTH_HEADER_NAME"] == ["true"]
}

# ─── Host users (unix socket) — unrestricted ─────────────────────
allow if {
	not is_sandbox
}

# ─── Sandbox default ─────────────────────────────────────────────
default allow_sandbox := false

# ─── Read-only operations ────────────────────────────────────────
allow_sandbox if {
	is_sandbox
	input.Method in {"GET", "HEAD"}
}

# ─── Image builds ────────────────────────────────────────────────
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	contains(input.PathPlain, "/build")
}

# ─── Image pulls ─────────────────────────────────────────────────
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	contains(input.PathPlain, "/images/create")
}

# ─── Container create — only if it belongs to the project ────────
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	contains(input.PathPlain, "/containers/create")
	project_container
}

# ─── BuildKit builder containers (no compose labels) ─────────────
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	contains(input.PathPlain, "/containers/create")
	buildkit_builder
}

buildkit_builder if {
	name := input.Body.Name
	startswith(name, "BUILDKIT_PREFIX")
}

allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	contains(input.PathPlain, "/containers/")
	buildkit_builder
}

# ─── Testcontainers containers (integration tests) ────────────────
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	contains(input.PathPlain, "/containers/create")
	testcontainers_container
}

testcontainers_container if {
	labels := input.Body.Labels
	labels["TESTCONTAINERS_LABEL_KEY"] == "TESTCONTAINERS_LABEL_VALUE"
}

# ─── Container lifecycle actions (closed allowlist) ──────────────
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	contains(input.PathPlain, "/containers/")
	lifecycle_action
}

lifecycle_action if {
	some action in {
		"start", "stop", "restart", "kill",
		"pause", "unpause", "wait", "update",
	}
	endswith(input.PathPlain, sprintf("/%s", [action]))
}

# ─── Container delete ────────────────────────────────────────────
# Allowed for any container: a delete request carries no labels, mounts or
# name, so the target cannot be attributed to a project at the authorization
# layer. "docker compose down" needs it. See SCHEMATIC.md's Limitations.
allow_sandbox if {
	is_sandbox
	input.Method == "DELETE"
	contains(input.PathPlain, "/containers/")
}

# ─── Network and volume operations ───────────────────────────────
# Create is project-scoped through the resource name in the request body
# (compose names its networks and volumes "<project>_<suffix>").
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	contains(input.PathPlain, "/networks/create")
	project_named_body
}

allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	contains(input.PathPlain, "/volumes/create")
	project_named_body
}

# Attach/detach and other in-place operations name the resource in the path.
allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	contains(input.PathPlain, "/networks/")
	project_resource
}

allow_sandbox if {
	is_sandbox
	input.Method == "POST"
	contains(input.PathPlain, "/volumes/")
	project_resource
}

# As with containers, a delete of a named resource carries nothing that
# attributes it to a project.
allow_sandbox if {
	is_sandbox
	input.Method == "DELETE"
	contains(input.PathPlain, "/networks/")
}

allow_sandbox if {
	is_sandbox
	input.Method == "DELETE"
	contains(input.PathPlain, "/volumes/")
}

# ─── Project resource detection ──────────────────────────────────
project_container if {
	labels := input.Body.Labels
	labels["com.docker.compose.project"] == "PROJECT_NAME"
}

project_named_body if {
	input.Body.Name == "PROJECT_NAME"
}

project_named_body if {
	startswith(input.Body.Name, "PROJECT_NAME_")
}

# The plugin enriches the input with PathArr (the request path split on "/"),
# so a resource named in the path is matched as a whole segment rather than as
# a substring of the path.
project_resource if {
	some segment in input.PathArr
	segment == "PROJECT_NAME"
}

project_resource if {
	some segment in input.PathArr
	startswith(segment, "PROJECT_NAME_")
}

# The plugin enriches the input with BindMounts: one object per bind mount,
# with Source, ReadOnly, and Resolved (the source path with symlinks resolved).
# Resolved is the value that closes the symlink bypass — a policy that checks
# the raw source path alone can be defeated with a symlink — but the plugin can
# only resolve paths it can read, so a managed-plugin deployment (which mounts
# only the policy directory) leaves it empty. Both forms are therefore checked.
# These rules attribute network and volume operations; container creation is
# attributed by the compose label (project_container), as in the original.
project_resource if {
	some mount in input.BindMounts
	contains(mount.Source, "PROJECT_DIR_PATH")
}

project_resource if {
	some mount in input.BindMounts
	contains(mount.Resolved, "PROJECT_DIR_PATH")
}

project_resource if {
	some mount in input.Body.HostConfig.Binds
	contains(mount, "PROJECT_DIR_PATH")
}

project_resource if {
	some mount in input.Body.HostConfig.Mounts
	contains(mount.Source, "PROJECT_DIR_PATH")
}

# ─── Final decision ──────────────────────────────────────────────
allow if {
	is_sandbox
	allow_sandbox
}
