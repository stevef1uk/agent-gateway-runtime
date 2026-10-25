#!/usr/bin/env python3
"""copy_secret.py <target-namespace> — read a Secret JSON on stdin, rebind its
namespace and strip runtime fields; print clean JSON for kubectl apply.
 Keeps kind/apiVersion so `kubectl apply -f -` validates."""
import json, sys

ns = sys.argv[1]
d = json.load(sys.stdin)
assert d.get("kind") == "Secret", "stdin must be a Secret JSON"
m = d.setdefault("metadata", {})
m.pop("resourceVersion", None)
m.pop("uid", None)
m.pop("creationTimestamp", None)
m.pop("annotations", None)
m.pop("managedFields", None)
m["namespace"] = ns
d.pop("runtimeClassName", None)
print(json.dumps(d))
