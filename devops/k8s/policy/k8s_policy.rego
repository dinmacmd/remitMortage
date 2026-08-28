package main

# 1. Enforce container resource limits
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits
  msg := sprintf("Container '%v' in Deployment '%v' is missing resource limits", [container.name, input.metadata.name])
}

deny[msg] {
  input.kind == "Pod"
  container := input.spec.containers[_]
  not container.resources.limits
  msg := sprintf("Container '%v' in Pod '%v' is missing resource limits", [container.name, input.metadata.name])
}

deny[msg] {
  input.kind == "Job"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits
  msg := sprintf("Container '%v' in Job '%v' is missing resource limits", [container.name, input.metadata.name])
}

# 2. Disallow :latest image tag
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  endswith(container.image, ":latest")
  msg := sprintf("Container '%v' in Deployment '%v' uses disallowed ':latest' image tag (%v)", [container.name, input.metadata.name, container.image])
}

deny[msg] {
  input.kind == "Pod"
  container := input.spec.containers[_]
  endswith(container.image, ":latest")
  msg := sprintf("Container '%v' in Pod '%v' uses disallowed ':latest' image tag (%v)", [container.name, input.metadata.name, container.image])
}

deny[msg] {
  input.kind == "Job"
  container := input.spec.template.spec.containers[_]
  endswith(container.image, ":latest")
  msg := sprintf("Container '%v' in Job '%v' uses disallowed ':latest' image tag (%v)", [container.name, input.metadata.name, container.image])
}

# 3. Require labels
deny[msg] {
  not input.metadata.labels.app
  not input.metadata.labels["app.kubernetes.io/name"]
  msg := sprintf("Manifest '%v' (%v) is missing required 'app' or 'app.kubernetes.io/name' label", [input.metadata.name, input.kind])
}
