# this Terraform module creates the same resources as project_init script and
# set the DNS zones structure.

terraform {
  backend "gcs" {}
}

variable "organization_name" {
  default = "gpii"
}

variable "organization_domain" {
  default = "gpii.net"
}

variable "project_name" {} # name of the project to create

variable "project_owner" {}

variable "billing_id" {}

variable "organization_id" {}

variable "serviceaccount_key" {}

# Id of the project which owns the credentials used by the provider
variable "project_id" {}

# We have to split all GCP APIs required by the project
# into 3 separate lists, because only some of them produce
# audit logs, and there is also a discrepancy in naming for storage API:
# https://cloud.google.com/logging/docs/audit/#services

# List of APIs in use by the project without audit configuration
variable "apis_without_audit_configuration" {
  default = [
    "bigquery-json.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "containerregistry.googleapis.com",
    "deploymentmanager.googleapis.com",
    "iamcredentials.googleapis.com",
    "oslogin.googleapis.com",
    "pubsub.googleapis.com",
    "replicapool.googleapis.com",
    "replicapoolupdater.googleapis.com",
    "resourceviews.googleapis.com",
    "stackdriver.googleapis.com",
    "storage-api.googleapis.com",
  ]
}

# List of APIs in use by the project with audit configuration
variable "apis_with_audit_configuration" {
  default = [
    "cloudkms.googleapis.com",
    "cloudtrace.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

# List of APIs solely for audit configuration
variable "apis_solely_for_audit_configuration" {
  default = [
    "storage.googleapis.com",
  ]
}

data "google_iam_policy" "admin" {
  binding {
    role = "roles/cloudkms.admin"

    members = [
      "serviceAccount:${google_service_account.project.email}",
    ]
  }

  binding {
    role = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

    members = [
      "serviceAccount:${google_service_account.project.email}",
    ]
  }

  binding {
    role = "roles/compute.admin"

    members = [
      "serviceAccount:${google_service_account.project.email}",
    ]
  }

  binding {
    role = "roles/container.clusterAdmin"

    members = [
      "serviceAccount:${google_service_account.project.email}",
    ]
  }

  binding {
    role = "roles/container.admin"

    members = [
      "serviceAccount:${google_service_account.project.email}",
    ]
  }

  binding {
    role = "roles/dns.admin"

    members = [
      "serviceAccount:${google_service_account.project.email}",
      "serviceAccount:projectowner@${var.project_id}.iam.gserviceaccount.com",
    ]
  }

  binding {
    role = "roles/iam.serviceAccountKeyAdmin"

    members = [
      "serviceAccount:${google_service_account.project.email}",
    ]
  }

  binding {
    role = "roles/iam.serviceAccountUser"

    members = [
      "serviceAccount:${google_service_account.project.email}",
    ]
  }

  binding {
    role = "roles/logging.configWriter"

    members = [
      "serviceAccount:${google_service_account.project.email}",
    ]
  }

  binding {
    role = "roles/monitoring.editor"

    members = [
      "serviceAccount:${google_service_account.project.email}",
    ]
  }

  binding {
    role = "roles/resourcemanager.projectIamAdmin"

    members = [
      "serviceAccount:${google_service_account.project.email}",
    ]
  }

  binding {
    role = "roles/serviceusage.serviceUsageAdmin"

    members = [
      "serviceAccount:${google_service_account.project.email}",
    ]
  }

  binding {
    role = "roles/storage.admin"

    members = [
      "serviceAccount:${google_service_account.project.email}",
      "serviceAccount:projectowner@${var.project_id}.iam.gserviceaccount.com",
    ]
  }

  binding {
    role = "roles/owner"

    members = [
      "${var.project_owner}",
    ]
  }

  binding {
    role = "roles/compute.serviceAgent"

    members = [
      "serviceAccount:service-${google_project.project.number}@compute-system.iam.gserviceaccount.com",
    ]
  }

  binding {
    role = "roles/container.serviceAgent"

    members = [
      "serviceAccount:service-${google_project.project.number}@container-engine-robot.iam.gserviceaccount.com",
    ]
  }

  binding {
    role = "roles/editor"

    members = [
      "serviceAccount:${google_project.project.number}-compute@developer.gserviceaccount.com",
      "serviceAccount:${google_project.project.number}@cloudservices.gserviceaccount.com",
      "serviceAccount:service-${google_project.project.number}@containerregistry.iam.gserviceaccount.com",
    ]
  }
}

provider "google" {
  credentials = "${var.serviceaccount_key}"
  project     = "${var.project_id}"
  region      = "us-central1"
}

# The dnsname and the dns domain must be computed for each new project created.
# The organization name may not match the organization domain.
locals {
  dnsname = "${replace(
              replace(
                google_project.project.name,
                "/([\\w]+)-([\\w]+)-([\\w]+)-?([-\\w]+)?/",
                "$4.$3.$2.${var.organization_domain}"),
              "/^\\./",
              "")
            }"
}

resource "google_project" "project" {
  name            = "${var.organization_name}-gcp-${var.project_name}"
  project_id      = "${var.organization_name}-gcp-${var.project_name}"
  billing_account = "${var.billing_id}"
  org_id          = "${var.organization_id}"
}

resource "google_project_services" "project" {
  project = "${google_project.project.project_id}"

  services = "${concat(var.apis_with_audit_configuration, var.apis_without_audit_configuration)}"
}

resource "google_project_iam_policy" "project" {
  project     = "${google_project.project.project_id}"
  policy_data = "${data.google_iam_policy.admin.policy_data}"
}

resource "google_service_account" "project" {
  account_id   = "projectowner"
  display_name = "Project owner service account"
  project      = "${google_project.project.project_id}"
}

resource "google_dns_managed_zone" "project" {
  project  = "${google_project.project.project_id}"
  name     = "${replace(local.dnsname, ".", "-")}"
  dns_name = "${local.dnsname}."

  depends_on = ["google_project_services.project",
    "google_project_iam_policy.project",
  ]
}

# Set the NS records in the parent zone of the parent project if the
# project_name has the pattern ${env}-${user}
resource "google_dns_record_set" "ns" {
  name         = "${local.dnsname}."
  managed_zone = "${element(split("-", var.project_name), 0)}-gcp-${replace(var.organization_domain, ".", "-")}"
  type         = "NS"
  ttl          = 3600
  project      = "${var.organization_name}-gcp-${element(split("-", var.project_name), 0)}"
  rrdatas      = ["${google_dns_managed_zone.project.name_servers}"]
  count        = "${length(split("-", var.project_name)) >= 2 ? 1 : 0}"
}

# Set the NS records in the gcp.$organization_domain zone of the
# $organization_name-gcp-common-$env if the project name doesn't have a hyphen.
resource "google_dns_record_set" "ns-root" {
  name         = "${local.dnsname}."
  managed_zone = "gcp-${replace(var.organization_domain, ".", "-")}"
  type         = "NS"
  ttl          = 3600
  project      = "${var.project_id}"
  rrdatas      = ["${google_dns_managed_zone.project.name_servers}"]
  count        = "${length(split("-", var.project_name)) == 1 ? 1 : 0}"
}

resource "google_storage_bucket" "project-tfstate" {
  project = "${google_project.project.project_id}"
  name    = "${var.organization_name}-gcp-${var.project_name}-tfstate"

  versioning = {
    enabled = "true"
  }
}
