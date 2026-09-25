#!/usr/bin/env python3
"""Return the client IDs already allowed on a Vault OIDC key.

A missing key yields an empty list. Any other API or TLS failure aborts the
plan so Terraform does not replace the live audience list with only its own.
"""

import json
import os
import ssl
import sys
import urllib.error
import urllib.request

query = json.load(sys.stdin)
key_name = query["key_name"]
address = os.environ["VAULT_ADDR"].rstrip("/")
token = os.environ["VAULT_TOKEN"]
ca_cert = os.environ.get("VAULT_CACERT")
context = ssl.create_default_context(cafile=ca_cert) if ca_cert else ssl.create_default_context()

request = urllib.request.Request(
    f"{address}/v1/identity/oidc/key/{key_name}",
    headers={"X-Vault-Token": token},
)
namespace = os.environ.get("VAULT_NAMESPACE")
if namespace:
    request.add_header("X-Vault-Namespace", namespace)

try:
    with urllib.request.urlopen(request, context=context) as response:
        payload = json.load(response)
    client_ids = payload.get("data", {}).get("allowed_client_ids") or []
except urllib.error.HTTPError as error:
    if error.code != 404:
        raise
    client_ids = []

json.dump({"allowed_client_ids": json.dumps(client_ids)}, sys.stdout)
