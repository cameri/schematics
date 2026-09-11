package docker.authz

# ─── OPA authorization policy for restricted Docker sandbox access ──
#
# This file contains PLACEHOLDERS that must be replaced with values from
# the Parameters table in SCHEMATIC.md before deployment:
#
#   SANDBOX_USERNAME          → P-4 value (e.g. "sandbox-agent")
#   AUTH_HEADER_NAME          → P-9 header name (e.g. "X-Sandbox-Agent")
#   PROJECT_NAME              → P-3 value (e.g. "backend-services")
#   PROJECT_DIR_PATH          → host path to the project (e.g.
#                               "/home/user/workspace/projects/myproject/")
#   BUILDKIT_PREFIX           → P-11 value (e.g. "/buildx_buildkit_")
#   TESTCONTAINERS_LABEL_KEY  → P-12 label key (e.g. "org.testcontainers")
#   TESTCONTAINERS_LABEL_VALUE→ P-12 label value (e.g. "true")
#
# Use `sed` to replace all occurrences of each placeholder, or edit by hand.
# Example: sed -i 's/SANDBOX_USERNAME/sandbox-agent/g' agent.rego

import future.keywords.in

default allow := false

# ─── Identity detection ──────────────────────────────────────────
is_sandbox if {
    input.User == "SANDBOX_USERNAME"
}

is_sandbox if {
    input.Headers["AUTH_HEADER_NAME"] == "true"
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

# ─── BuildKit builder containers (no compose labels) ──────────────
allow_sandbox if {
    is_sandbox
    input.Method == "POST"
    contains(input.PathPlain, "/containers/create")
    buildkit_builder
}

buildkit_builder if {
    body := input.Body
    name := object.get(body, ["Name"], "")
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
    body := input.Body
    labels := object.get(body, ["Labels"], {})
    object.get(labels, ["TESTCONTAINERS_LABEL_KEY"], "") == "TESTCONTAINERS_LABEL_VALUE"
}

# ─── Container lifecycle actions (closed allowlist) ──────────────
allow_sandbox if {
    is_sandbox
    input.Method == "POST"
    contains(input.PathPlain, "/containers/")
    lifecycle_action
}

lifecycle_action if {
    some action
    actions := {
        "start", "stop", "restart", "kill",
        "pause", "unpause", "wait", "update",
    }
    action = actions[_]
    endswith(input.PathPlain, sprintf("/%s", [action]))
}

# ─── Container delete ────────────────────────────────────────────
allow_sandbox if {
    is_sandbox
    input.Method == "DELETE"
    contains(input.PathPlain, "/containers/")
}

# ─── Network operations — only for project ───────────────────────
allow_sandbox if {
    is_sandbox
    input.Method == "POST"
    contains(input.PathPlain, "/networks/")
    project_resource
}

allow_sandbox if {
    is_sandbox
    input.Method == "DELETE"
    contains(input.PathPlain, "/networks/")
}

# ─── Volume operations — only for project ────────────────────────
allow_sandbox if {
    is_sandbox
    input.Method == "POST"
    contains(input.PathPlain, "/volumes/")
    project_resource
}

allow_sandbox if {
    is_sandbox
    input.Method == "DELETE"
    contains(input.PathPlain, "/volumes/")
}

# ─── Project resource detection ──────────────────────────────────
project_container if {
    body := input.Body
    labels := object.get(body, ["Labels"], {})
    object.get(labels, ["com.docker.compose.project"], "") == "PROJECT_NAME"
}

project_resource if {
    contains(input.Path, "PROJECT_NAME")
}

project_resource if {
    some mount
    mounts := object.get(input.Body, ["HostConfig", "Binds"], [])
    mount = mounts[_]
    contains(mount, "PROJECT_DIR_PATH")
}

project_resource if {
    some m
    mounts := object.get(input.Body, ["HostConfig", "Mounts"], [])
    m = mounts[_]
    source := object.get(m, ["Source"], "")
    contains(source, "PROJECT_DIR_PATH")
}

# ─── Final decision ──────────────────────────────────────────────
allow if {
    is_sandbox
    allow_sandbox
}