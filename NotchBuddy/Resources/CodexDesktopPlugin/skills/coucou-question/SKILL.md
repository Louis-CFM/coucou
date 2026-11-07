---
name: coucou-question
description: Ask the user a question in Coucou, or collect a new instruction there, and continue this Codex conversation with their answer. Use when the user requests Coucou questions or invokes this skill.
---

Use the Coucou `ask_question` MCP tool to show a question in the local Coucou island.
Pass the current project's absolute directory as `cwd`, and one to four questions
with unique `id` values. Give each question its actual question text, a short
optional header, and optional choices with `label` and `description`. Set
`isOther: true` to allow a typed answer. For free-form input, use `options: []`.

If the user asks to enter a new instruction in Coucou, show one free-form question
asking what they want to do next. Treat its answer as input to this conversation
and continue here. This tool does not send instructions to another conversation.

Wait for the tool result before continuing. Use only answers the tool actually
returns. If Coucou is unavailable, the question times out, or the call is cancelled,
ask again in this original Codex conversation. Never infer an answer or treat a
failed tool call as permission. Do not silently retry a cancelled question.

This plugin routes questions made through its tool. It does not intercept every
built-in Codex question or connect to private desktop RPC endpoints. It requires
the GitHub macOS Coucou build running on the same computer and Python 3.
