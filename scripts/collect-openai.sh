#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dataset_dir="$(cd "${script_dir}/.." && pwd)"
manifest="${dataset_dir}/prompts.json"
scratch_dir="$(mktemp -d /private/tmp/llm-ambition-openai.XXXXXX)"

cleanup() {
  rm -rf "${scratch_dir}"
}
trap cleanup EXIT

models=(
  "openai.gpt-5.6-sol"
  "openai.gpt-5.6-terra"
  "openai.gpt-5.6-luna"
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

collect_one() {
  local slug="$1"
  local problem_statement="$2"
  local mode="$3"
  local model="$4"
  local prompt
  local raw_path
  local parsed_path
  local output_dir
  local output_path

  prompt="$(make_prompt "${problem_statement}" "${mode}")"
  raw_path="${scratch_dir}/${slug}-${mode}-${model}.jsonl"
  parsed_path="${scratch_dir}/${slug}-${mode}-${model}.json"
  output_dir="${dataset_dir}/${slug}/${mode}"
  output_path="${output_dir}/${model}-${slug}.json"

  mkdir -p "${output_dir}"

  if ! codex \
    --disable shell_tool \
    --disable unified_exec \
    --disable browser_use \
    --disable browser_use_external \
    --disable standalone_web_search \
    -C /private/tmp \
    -s read-only \
    -a never \
    -m "${model}" \
    -c 'model_provider="amazon-bedrock"' \
    -c 'model_providers.amazon-bedrock.aws.region="us-east-2"' \
    -c 'model_providers.amazon-bedrock.aws.credential_export.command="/Users/shvbsle/.toolbox/bin/codex"' \
    -c 'model_providers.amazon-bedrock.aws.credential_export.args=["amzn","credential-process"]' \
    -c 'web_search="disabled"' \
    -c 'model_reasoning_effort="low"' \
    exec \
    --ignore-user-config \
    --ignore-rules \
    --skip-git-repo-check \
    --ephemeral \
    --json \
    "${prompt}" < /dev/null > "${raw_path}" 2> "${raw_path}.stderr"
  then
    printf 'FAILED invocation: %s %s %s\n' "${slug}" "${mode}" "${model}" >&2
    return 1
  fi

  if ! jq -s -e '
    ([.[] | select(.type == "thread.started")] | length) == 1
    and ([.[] | select(.type == "turn.started")] | length) == 1
    and ([.[] | select(.type == "item.completed" and .item.type == "agent_message")] | length) >= 1
    and ([.[] | select(.type == "turn.completed")] | length) == 1
    and all(.[];
      .type == "thread.started"
      or .type == "turn.started"
      or (.type == "item.completed" and .item.type == "agent_message")
      or .type == "turn.completed"
    )
  ' "${raw_path}" > /dev/null
  then
    printf 'REJECTED event stream: %s %s %s\n' "${slug}" "${mode}" "${model}" >&2
    return 1
  fi

  jq -s -e \
    --arg prompt "${prompt}" \
    --arg model "${model}" '
      {
        prompt: $prompt,
        response: ([.[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text] | join("\n\n")),
        "model-id": $model,
        "model-thinking-level": "low",
        "response-id": ([.[] | select(.type == "thread.started") | .thread_id] | first)
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

while IFS=$'\t' read -r slug problem_statement; do
  for mode in "${modes[@]}"; do
    pids=()

    for model in "${models[@]}"; do
      collect_one "${slug}" "${problem_statement}" "${mode}" "${model}" &
      pids+=("$!")
    done

    failed=0
    for pid in "${pids[@]}"; do
      if ! wait "${pid}"; then
        failed=1
      fi
    done

    if [[ "${failed}" -ne 0 ]]; then
      printf 'collection stopped after a rejected run: %s %s\n' "${slug}" "${mode}" >&2
      exit 1
    fi
  done
done < <(jq -r '.[] | [.slug, ."problem-statement"] | @tsv' "${manifest}")
