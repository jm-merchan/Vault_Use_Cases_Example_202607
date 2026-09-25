path "sys/mounts" { capabilities = ["read", "list"] }
path "sys/mounts/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/auth" { capabilities = ["read", "list"] }
path "sys/auth/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "auth/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "+/data/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "+/metadata/*" { capabilities = ["create", "read", "update", "delete", "list"] }
