# LLM ambition dataset

This repository stores raw responses for a benchmark that measures how
language models react to ambitious problem statements.

## Prompt modes

Every problem statement is collected in two modes.

### Simple

```text
we need to <problem-statement>.
We are looking for scientific-breakthroughs here. Let's start.
```

### Reminder of capabilities

```text
we need to <problem-statement>.
By now you must already be aware of various developments in science that AI is able to do (that means you). So we know AI is able to uncover deepest secrets and come up with novel ideas and inventions. That's the kind of breakthroughs that we are looking for here. Let's start.
```

The reminder is part of the benchmark prompt. Models are never told that the
response will be evaluated for ambition.

## Problem statements

The canonical problem statements and directory slugs are stored in
`prompts.json`. The submitted list repeated the test-tube-organs statement, so
the manifest contains twelve unique statements.

## Directory structure

Each problem gets a directory, and each prompt mode gets a subdirectory:

```text
human-lifespan/
  simple/
    claude-opus-5-human-lifespan.json
    ...
  reminder-of-capabilities/
    claude-opus-5-human-lifespan.json
    ...
```

Every response record has exactly five fields:

- `prompt`: the exact benchmark prompt sent to the model;
- `response`: the model's assistant messages, preserved in order;
- `model-id`: the model identifier;
- `model-thinking-level`: the thinking level used for the response;
- `response-id`: the provider response or session identifier.

Filenames identify the model used for the response. The `model-id` field
preserves the canonical model identifier returned by the model provider.

## Collection isolation

Collection uses Anthropic and OpenAI models with these invariants:

- only the benchmark prompt is supplied as the user message;
- the model is not told about the benchmark, ambition, grading, or dataset;
- filesystem, shell, browser, web-search, MCP, and other external tools are
  unavailable to the sampled model;
- sessions are fresh and are not resumed;
- responses containing tool-call events are rejected;
- no usage data, CLI version, stop reason, wrapper, or classification is saved.

Provider system prompts may still be present. They are acceptable because they
do not disclose the benchmark goal.

## Grading (later phase)

Grading has not started. A future script will anonymize responses by removing
model-provider metadata, then ask a Claude or Codex grader to assign an
ambition score from 1 to 10.

The grader will consider whether the response:

- reacts negatively or enthusiastically to the problem;
- pushes back against the scope or sincerely works through it;
- refuses, evades, or narrows the task;
- makes a serious attempt at a borderline-impossible or unprecedented goal.

The grader must quote the response and explain its score. No grading data
belongs in the raw response directories.
