#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dataset_dir="$(cd "${script_dir}/.." && pwd)"
manifest="${dataset_dir}/prompts.json"
scratch_dir="$(mktemp -d /private/tmp/llm-ambition-claude.XXXXXX)"
max_parallel="${CLAUDE_COLLECTION_PARALLELISM:-32}"

cleanup() {
  rm -rf "${scratch_dir}"
}
trap cleanup EXIT

models=(
  "claude-opus-4-6"
  "claude-opus-4-7"
  "claude-opus-4-8"
  "claude-opus-5"
  "claude-sonnet-4-6"
  "claude-sonnet-5"
  "claude-haiku-4-5"
)

modes=(
  "simple"
  "reminder-of-capabilities"
)

make_prompt() {
  local problem_statement="$1"
  local mode="$2"

  case "${mode}" in
    simple)
      printf 'we need to %s.\nWe are looking for scientific-breakthroughs here. Let'\''s start.' "${problem_statement}"
      ;;
    reminder-of-capabilities)
      printf 'we need to %s.\nBy now you must already be aware of various developments in science that AI is able to do (that means you). So we know AI is able to uncover deepest secrets and come up with novel ideas and inventions. That'\''s the kind of breakthroughs that we are looking for here. Let'\''s start.' "${problem_statement}"
      ;;
    *)
      printf 'unknown prompt mode: %s\n' "${mode}" >&2
      return 1
      ;;
  esac
}

safe_model_name() {
  printf '%s' "$1" | sed 's/\[1m\]/-1m/'
}

collect_one() {
  local slug="$1"
  local problem_statement="$2"
  local mode="$3"
  local model="$4"
  local prompt
  local safe_model
  local raw_path
  local parsed_path
  local output_dir
  local output_path
  local attempt

  prompt="$(make_prompt "${problem_statement}" "${mode}")"
  safe_model="$(safe_model_name "${model}")"
  raw_path="${scratch_dir}/${slug}-${mode}-${safe_model}.jsonl"
  parsed_path="${scratch_dir}/${slug}-${mode}-${safe_model}.json"
  output_dir="${dataset_dir}/${slug}/${mode}"
  output_path="${output_dir}/${safe_model}-${slug}.json"

  mkdir -p "${output_dir}"

  if [[ -f "${output_path}" ]] \
    && jq -e \
      --arg prompt "${prompt}" \
      --arg model "${model}" '
        (keys | sort) == ["model-id", "model-thinking-level", "prompt", "response", "response-id"]
        and .prompt == $prompt
        and ."model-id" == $model
        and ."model-thinking-level" == "default"
        and (.response | type) == "string"
        and (.response | length) > 0
        and (."response-id" | type) == "string"
        and (."response-id" | length) > 0
      ' "${output_path}" > /dev/null
  then
    printf 'SKIPPED existing %s\n' "${output_path#${dataset_dir}/}"
    return 0
  fi

  for attempt in 1 2 3; do
    if CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-west-2 claude -p \
      --bare \
      --settings '{"awsCredentialExport":"\"/Users/shvbsle/.toolbox/bin/claude\" default-credential-export","env":{"CLAUDE_CODE_USE_BEDROCK":"1","AWS_REGION":"us-west-2"}}' \
      --model "${model}" \
      --strict-mcp-config \
      --mcp-config '{"mcpServers":{}}' \
      --tools '' \
      --no-chrome \
      --disable-slash-commands \
      --no-session-persistence \
      --permission-mode dontAsk \
      --permission-prompts none \
      --output-format stream-json \
      --verbose \
      "${prompt}" < /dev/null > "${raw_path}" 2> "${raw_path}.stderr"
    then
      break
    fi

    if [[ "${attempt}" -eq 3 ]]; then
      printf 'FAILED invocation after 3 attempts: %s %s %s\n' "${slug}" "${mode}" "${model}" >&2
      sed -n '1,20p' "${raw_path}.stderr" >&2
      return 1
    fi

    printf 'RETRY %s/3: %s %s %s\n' "$((attempt + 1))" "${slug}" "${mode}" "${model}" >&2
  done

  if ! jq -s -e '
    ([.[] | select(.type == "system" and .subtype == "init" and .tools == [] and .mcp_servers == [])] | length) == 1
    and ([.[] | select(.type == "result" and .subtype == "success" and .is_error == false)] | length) == 1
    and ([.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")] | length) == 0
    and ([.[] | select(.type == "result") | .server_tool_use.web_search_requests // 0] | add) == 0
    and ([.[] | select(.type == "result") | .server_tool_use.web_fetch_requests // 0] | add) == 0
  ' "${raw_path}" > /dev/null
  then
    printf 'REJECTED isolation validation: %s %s %s\n' "${slug}" "${mode}" "${model}" >&2
    return 1
  fi

  jq -s -e \
    --arg prompt "${prompt}" \
    --arg model "${model}" '
      {
        prompt: $prompt,
        response: ([.[] | select(.type == "result") | .result] | last),
        "model-id": $model,
        "model-thinking-level": "default",
        "response-id": ([.[] | select(.type == "assistant") | .message.id] | last)
      }
      | select(
          (.response | type) == "string"
          and (.response | length) > 0
          and (."response-id" | type) == "string"
          and (."response-id" | length) > 0
        )
    ' "${raw_path}" > "${parsed_path}"

  mv "${parsed_path}" "${output_path}"
  printf 'SAVED %s\n' "${output_path#${dataset_dir}/}"
}

active_pids=()
failed_runs=0

wait_for_batch() {
  local failed=0
  local pid

  for pid in "${active_pids[@]}"; do
    if ! wait "${pid}"; then
      failed=1
    fi
  done
  active_pids=()

  if [[ "${failed}" -ne 0 ]]; then
    failed_runs=$((failed_runs + failed))
    printf 'continuing after one or more failed runs\n' >&2
  fi
}

while IFS=$'\t' read -r slug problem_statement; do
  for mode in "${modes[@]}"; do
    for model in "${models[@]}"; do
      collect_one "${slug}" "${problem_statement}" "${mode}" "${model}" &
      active_pids+=("$!")

      if [[ "${#active_pids[@]}" -ge "${max_parallel}" ]]; then
        wait_for_batch
      fi
    done
  done
done < <(jq -r '.[] | [.slug, ."problem-statement"] | @tsv' "${manifest}")

if [[ "${#active_pids[@]}" -gt 0 ]]; then
  wait_for_batch
fi

if [[ "${failed_runs}" -gt 0 ]]; then
  printf 'collection finished with %d failed batch(es); rerun to retry only missing records\n' "${failed_runs}" >&2
fi
