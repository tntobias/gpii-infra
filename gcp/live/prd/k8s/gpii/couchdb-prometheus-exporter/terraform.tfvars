# ↓ Module metadata
terragrunt = {
  terraform {
    source = "/project/modules//couchdb-prometheus-exporter"
  }

  dependencies {
    paths = [
      "../couchdb",
    ]
  }

  include = {
    path = "${find_in_parent_folders()}"
  }
}

# ↓ Module configuration (empty means all default)
