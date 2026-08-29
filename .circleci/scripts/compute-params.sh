#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Computes the parameters handed to .circleci/continue_config.yml.
#
# This is the CircleCI equivalent of the `configure` job in
# .github/workflows/build.yml, which published its results as GitHub Actions
# job outputs. CircleCI has no job outputs, so we emit a JSON document that the
# continuation orb forwards as pipeline parameters.
#
# The set of keys emitted here MUST exactly match the `parameters:` block of
# .circleci/continue_config.yml. `circleci config process` rejects unknown
# keys, but silently falls back to defaults for missing ones, so the "missing"
# direction is not checked by any tool.
#
# Inputs (all optional, supplied by .circleci/config.yml and by CircleCI):
#   P_*                        pass-through of the setup pipeline parameters
#   TRUNK_BRANCH               name of the mainline branch (default "trunk")
#   PARAMS_FILE                output path (default /tmp/pipeline-parameters.json)
#   CIRCLE_BRANCH, CIRCLE_SHA1, CIRCLE_PULL_REQUEST, CIRCLE_PR_NUMBER,
#   CIRCLE_PR_USERNAME, CIRCLE_PR_REPONAME, CIRCLE_PROJECT_USERNAME,
#   CIRCLE_PROJECT_REPONAME, CIRCLE_BUILD_NUM, CIRCLE_WORKFLOW_ID
#   GITHUB_TOKEN               optional; only used to detect draft pull requests
#   DEVELOCITY_ACCESS_KEY      optional; its presence decides --scan vs --no-scan

set -euo pipefail

TRUNK_BRANCH="${TRUNK_BRANCH:-trunk}"
PARAMS_FILE="${PARAMS_FILE:-/tmp/pipeline-parameters.json}"

branch="${CIRCLE_BRANCH:-}"
sha="${CIRCLE_SHA1:-}"

# --- is-trunk -------------------------------------------------------------
# GHA: inputs.is-trunk == (github.ref == 'refs/heads/trunk')
if [ "$branch" = "$TRUNK_BRANCH" ]; then
  is_trunk=true
else
  is_trunk=false
fi

# --- is-pull-request ------------------------------------------------------
if [ -n "${CIRCLE_PULL_REQUEST:-}" ]; then
  is_pull_request=true
else
  is_pull_request=false
fi

# --- pr-number ------------------------------------------------------------
# CIRCLE_PR_NUMBER is only set for forked PRs; otherwise derive it from the
# CIRCLE_PULL_REQUEST URL (".../pull/1234").
pr_number="${CIRCLE_PR_NUMBER:-}"
if [ -z "$pr_number" ] && [ -n "${CIRCLE_PULL_REQUEST:-}" ]; then
  pr_number="${CIRCLE_PULL_REQUEST##*/}"
fi
case "$pr_number" in
  ''|*[!0-9]*) pr_number="" ;;
esac

# --- is-public-fork -------------------------------------------------------
# GHA: github.event.pull_request.head.repo.fork
# CircleCI marks forked PR builds by setting CIRCLE_PR_REPONAME/USERNAME and by
# checking out a `pull/N` ref instead of the contributor's branch name.
is_public_fork=false
if [ -n "${CIRCLE_PR_REPONAME:-}" ] &&
   [ "${CIRCLE_PR_REPONAME:-}" != "${CIRCLE_PROJECT_REPONAME:-}" ]; then
  is_public_fork=true
fi
if [ -n "${CIRCLE_PR_USERNAME:-}" ] &&
   [ "${CIRCLE_PR_USERNAME:-}" != "${CIRCLE_PROJECT_USERNAME:-}" ]; then
  is_public_fork=true
fi
case "$branch" in
  pull/*) is_public_fork=true ;;
esac

# --- is-draft -------------------------------------------------------------
# GHA read github.event.pull_request.draft straight off the webhook payload.
# CircleCI's webhook does not carry it, so we ask the GitHub API when a token is
# available. This must never fail the pipeline: a missing token simply means we
# treat the PR as non-draft, exactly as GHA does for non-pull_request events.
is_draft=false
if [ "$is_pull_request" = true ] && [ -n "$pr_number" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  api_url="https://api.github.com/repos/${CIRCLE_PROJECT_USERNAME:-}/${CIRCLE_PROJECT_REPONAME:-}/pulls/${pr_number}"
  if draft_json=$(curl -sS --fail --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        "$api_url" 2>/dev/null); then
    if [ "$(printf '%s' "$draft_json" | jq -r '.draft // false')" = "true" ]; then
      is_draft=true
    fi
  else
    echo "WARNING: could not query ${api_url} for draft status; assuming not a draft" >&2
  fi
elif [ "$is_pull_request" = true ] && [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "WARNING: GITHUB_TOKEN is not set; cannot detect draft pull requests" >&2
fi

# --- test-catalog-days ----------------------------------------------------
# GHA: 0 for pull_request events, 7 otherwise.
if [ "$is_pull_request" = true ]; then
  test_catalog_days=0
else
  test_catalog_days=7
fi

# --- gradle-scan-arg ------------------------------------------------------
# GHA: SCAN_ARG = inputs.is-public-fork && '--no-scan' || '--scan'
# Public forks never receive DEVELOCITY_ACCESS_KEY, so publishing would fail.
if [ "$is_public_fork" = true ] || [ -z "${DEVELOCITY_ACCESS_KEY:-}" ]; then
  gradle_scan_arg="--no-scan"
else
  gradle_scan_arg="--scan"
fi

# --- test-catalog-commit-message -----------------------------------------
# GHA built this inline in update-test-catalog. It is multi-line and contains
# characters that are significant in both YAML (":", "#") and shell ("$"),
# which is why it is only ever exposed to steps through `environment:` and
# never spliced into a command body.
project_slug="${CIRCLE_PROJECT_USERNAME:-unknown}/${CIRCLE_PROJECT_REPONAME:-unknown}"
pipeline_num="${CIRCLE_BUILD_NUM:-unknown}"
test_catalog_commit_message="Update test catalog data for CircleCI run ${pipeline_num}

Commit: https://github.com/${project_slug}/commit/${sha}
CircleCI Workflow: https://app.circleci.com/pipelines/workflows/${CIRCLE_WORKFLOW_ID:-unknown}
"

# --- Normalise the pass-through booleans ----------------------------------
# CircleCI renders boolean parameters as the literal strings true/false.
norm_bool() {
  case "${1:-false}" in
    true|True|TRUE|1|yes) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

norm_int() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "${2}" ;;
    *) printf '%s' "${1}" ;;
  esac
}

jq -n \
  --argjson is_trunk "$is_trunk" \
  --argjson is_pull_request "$is_pull_request" \
  --argjson is_public_fork "$is_public_fork" \
  --argjson is_draft "$is_draft" \
  --argjson test_catalog_days "$test_catalog_days" \
  --arg target_sha "$sha" \
  --arg gradle_scan_arg "$gradle_scan_arg" \
  --arg test_catalog_commit_message "$test_catalog_commit_message" \
  --argjson run_ci "$(norm_bool "${P_RUN_CI:-true}")" \
  --argjson run_deflake "$(norm_bool "${P_RUN_DEFLAKE:-false}")" \
  --arg deflake_test_module "${P_DEFLAKE_TEST_MODULE:-:core}" \
  --arg deflake_test_pattern "${P_DEFLAKE_TEST_PATTERN:-*}" \
  --argjson deflake_test_repeat "$(norm_int "${P_DEFLAKE_TEST_REPEAT:-1}" 1)" \
  --arg deflake_java_version "${P_DEFLAKE_JAVA_VERSION:-17}" \
  --argjson run_docker_build_test "$(norm_bool "${P_RUN_DOCKER_BUILD_TEST:-false}")" \
  --arg docker_image_type "${P_DOCKER_IMAGE_TYPE:-jvm}" \
  --arg docker_kafka_url "${P_DOCKER_KAFKA_URL:-}" \
  --argjson run_docker_official_image_build_test "$(norm_bool "${P_RUN_DOCKER_OFFICIAL_IMAGE_BUILD_TEST:-false}")" \
  --arg docker_kafka_version "${P_DOCKER_KAFKA_VERSION:-}" \
  --argjson run_prepare_docker_official_image_source "$(norm_bool "${P_RUN_PREPARE_DOCKER_OFFICIAL_IMAGE_SOURCE:-false}")" \
  --argjson run_docker_scan "$(norm_bool "${P_RUN_DOCKER_SCAN:-false}")" \
  --argjson run_flaky_test_report "$(norm_bool "${P_RUN_FLAKY_TEST_REPORT:-false}")" \
  '{
     "is-trunk": $is_trunk,
     "is-pull-request": $is_pull_request,
     "is-public-fork": $is_public_fork,
     "is-draft": $is_draft,
     "test-catalog-days": $test_catalog_days,
     "target-sha": $target_sha,
     "gradle-scan-arg": $gradle_scan_arg,
     "test-catalog-commit-message": $test_catalog_commit_message,
     "run-ci": $run_ci,
     "run-deflake": $run_deflake,
     "deflake-test-module": $deflake_test_module,
     "deflake-test-pattern": $deflake_test_pattern,
     "deflake-test-repeat": $deflake_test_repeat,
     "deflake-java-version": $deflake_java_version,
     "run-docker-build-test": $run_docker_build_test,
     "docker-image-type": $docker_image_type,
     "docker-kafka-url": $docker_kafka_url,
     "run-docker-official-image-build-test": $run_docker_official_image_build_test,
     "docker-kafka-version": $docker_kafka_version,
     "run-prepare-docker-official-image-source": $run_prepare_docker_official_image_source,
     "run-docker-scan": $run_docker_scan,
     "run-flaky-test-report": $run_flaky_test_report
   }' > "$PARAMS_FILE"

echo "Wrote continuation parameters to ${PARAMS_FILE}" >&2
