# Models for call summaries

In Settings → Local models, connect Ollama, LM Studio or an OpenAI-compatible server. Choose that provider's model in Chat, then select the provider under Flow → Settings → Notetaker → Summaries. Claude and No summary remain available; existing preferences keep their selection.

Summaries send transcript text to the selected provider without chat history, files, audio or tools. A local provider uses only its configured server and saved model, never an automatic cloud fallback. A server on another machine receives that text. Custom server credentials remain bound to the address where they were entered and use the existing OS secret store.

Requests do not follow redirects. Each local summary has a two-minute deadline, bounded response sizes, and requires the stream's completion marker. Timeout, incomplete response and provider errors appear on the note; an existing summary remains available. No summary skips automatic and manual summary requests. Existing Claude API/subscription routing and its model fallback remain in place for the Claude choice.

Dictation clean-up and voice-provider selection are separate from this setting.
