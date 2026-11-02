#!/usr/bin/env bash
# Prints chart values for an OpenShift run, following docs/OPENSHIFT.md:
#   - service account is created (SCC is granted to it),
#   - openshift.io/required-scc annotation on every pod: *.podAnnotations of all components
#     and tests.annotations (the test is a standalone Pod); commonAnnotations do not reach pods,
#   - security contexts enabled or not (see the compatibility table in OPENSHIFT.md),
#   - Docs is published via Route.
# The lists of *.containerSecurityContext and *.podAnnotations keys are read from values.yaml,
# so new components are covered automatically.
#
# usage: openshift-values.sh <values.yaml> <scc> <contexts: on|off> <route-host>
set -euo pipefail

VALUES_FILE="$1" SCC="$2" CONTEXTS="$3" ROUTE_HOST="$4"
export SCC ROUTE_HOST VALUES_FILE

enabled=false; [[ "$CONTEXTS" == "on" ]] && enabled=true
export enabled

yq '
  [ .. | select(tag == "!!map" and has("containerSecurityContext")) | path ]
  | .[] as $p ireduce ({}; setpath($p + ["containerSecurityContext", "enabled"]; env(enabled)))
  | .podSecurityContext.enabled = env(enabled)
  | .serviceAccount.create = true
  | . * ([ load(strenv(VALUES_FILE)) | .. | select(tag == "!!map" and has("podAnnotations")) | path ]
         | .[] as $p ireduce ({}; setpath($p + ["podAnnotations", "openshift.io/required-scc"]; strenv(SCC))))
  | .tests.annotations."openshift.io/required-scc" = strenv(SCC)
  | .openshift.route.enabled = true
  | .openshift.route.host = strenv(ROUTE_HOST)
' "$VALUES_FILE"
