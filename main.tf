/**
 * Copyright 2019 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  account_billing = var.grant_billing_role && var.billing_account_id != ""
  org_billing     = var.grant_billing_role && var.billing_account_id == "" && var.org_id != ""
  prefix          = var.prefix != "" ? "${var.prefix}-" : ""
  xpn             = var.grant_xpn_roles && var.org_id != ""

  # New mode: service_accounts map
  # Legacy mode: names list
  service_accounts_map = length(var.service_accounts) > 0 ? {
    for key, sa in var.service_accounts : key => {
      account_id = sa.account_id
      display_name = sa.display_name != null && sa.display_name != "" ? sa.display_name : (
        var.display_name != "" ? var.display_name : sa.account_id
      )

      description = sa.description != null && sa.description != "" ? sa.description : var.description
      disabled    = lookup(var.disabled, key, false)
    }
    } : {
    for name in var.names : name => {
      account_id   = "${local.prefix}${lower(name)}"
      display_name = var.display_name
      description  = index(var.names, name) >= length(var.descriptions) ? var.description : element(var.descriptions, index(var.names, name))
      disabled     = lookup(var.disabled, name, false)
    }
  }

  service_account_keys = toset(keys(local.service_accounts_map))

  service_accounts_list = [for account in google_service_account.service_accounts : account]
  emails_list           = [for account in local.service_accounts_list : account.email]
  iam_emails_list       = [for email in local.emails_list : "serviceAccount:${email}"]

  name_role_pairs = setproduct(local.service_account_keys, toset(var.project_roles))

  project_roles_map_data = zipmap(
    [for pair in local.name_role_pairs : "${pair[0]}-${pair[1]}"],
    [for pair in local.name_role_pairs : {
      name = pair[0]
      role = pair[1]
    }]
  )
}

# create service accounts
resource "google_service_account" "service_accounts" {
  for_each = local.service_accounts_map

  account_id   = each.value.account_id
  display_name = each.value.display_name
  description  = each.value.description
  project      = var.project_id
  disabled     = each.value.disabled
}

# common roles
resource "google_project_iam_member" "project-roles" {
  for_each = local.project_roles_map_data

  project = element(
    split(
      "=>",
      each.value.role
    ),
    0,
  )

  role = element(
    split(
      "=>",
      each.value.role
    ),
    1,
  )

  member = "serviceAccount:${google_service_account.service_accounts[each.value.name].email}"
}

# conditionally assign billing user role at the org level
resource "google_organization_iam_member" "billing_user" {
  for_each = local.org_billing ? local.service_account_keys : toset([])
  org_id   = var.org_id
  role     = "roles/billing.user"
  member   = "serviceAccount:${google_service_account.service_accounts[each.value].email}"
}

# conditionally assign billing user role on a specific billing account
resource "google_billing_account_iam_member" "billing_user" {
  for_each           = local.account_billing ? local.service_account_keys : toset([])
  billing_account_id = var.billing_account_id
  role               = "roles/billing.user"
  member             = "serviceAccount:${google_service_account.service_accounts[each.value].email}"
}

# conditionally assign roles for shared VPC
# ref: https://cloud.google.com/vpc/docs/shared-vpc

resource "google_organization_iam_member" "xpn_admin" {
  for_each = local.xpn ? local.service_account_keys : toset([])
  org_id   = var.org_id
  role     = "roles/compute.xpnAdmin"
  member   = "serviceAccount:${google_service_account.service_accounts[each.value].email}"
}

resource "google_organization_iam_member" "organization_viewer" {
  for_each = local.xpn ? local.service_account_keys : toset([])
  org_id   = var.org_id
  role     = "roles/resourcemanager.organizationViewer"
  member   = "serviceAccount:${google_service_account.service_accounts[each.value].email}"
}

# keys
resource "google_service_account_key" "keys" {
  for_each           = var.generate_keys ? local.service_account_keys : toset([])
  service_account_id = google_service_account.service_accounts[each.value].email
}
