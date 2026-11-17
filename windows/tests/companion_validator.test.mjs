import test from "node:test";
import assert from "node:assert/strict";

import { MessageValidator } from "../src/companion/validator.ts";

test("MessageValidator strips <think> reasoning tags and thought blocks", () => {
  const input = "<think>The user is returning from a break. I should be warm.</think>Welcome back, Alex! Let's get to it ✨";
  const cleaned = MessageValidator.sanitizeAndValidate(input);
  assert.equal(cleaned, "Welcome back, Alex! Let's get to it ✨");

  const input2 = "[thought]Internal reasoning[/thought]Good to see you again! 🌱";
  const cleaned2 = MessageValidator.sanitizeAndValidate(input2);
  assert.equal(cleaned2, "Good to see you again! 🌱");
});

test("MessageValidator rejects unclosed think tags and reasoning headers", () => {
  const unclosed = "<think>Deliberating about user activity... I should say hello";
  assert.equal(MessageValidator.sanitizeAndValidate(unclosed), null);

  const header = "Thinking Process: The user is in VS Code. Output: Sip some water.";
  assert.equal(MessageValidator.sanitizeAndValidate(header), null);
});

test("MessageValidator neutralizes quotes, conversational preambles and markdown", () => {
  const input = 'Mochi says: "**Welcome back!** Let\'s crush this project."';
  const cleaned = MessageValidator.sanitizeAndValidate(input);
  assert.equal(cleaned, "Welcome back! Let's crush this project.");
});

test("MessageValidator rejects overly short, empty, or unparseable text", () => {
  assert.equal(MessageValidator.sanitizeAndValidate(""), null);
  assert.equal(MessageValidator.sanitizeAndValidate("   "), null);
  assert.equal(MessageValidator.sanitizeAndValidate("Hi"), null);
  assert.equal(MessageValidator.sanitizeAndValidate("<think>only thoughts</think>"), null);
});

test("MessageValidator clamps long text gracefully at whole word boundary with ellipsis", () => {
  const longText = "This is a remarkably long greeting sentence that clearly exceeds the maximum seventy-two grapheme limit of the dynamic island notch.";
  const cleaned = MessageValidator.sanitizeAndValidate(longText);

  assert.ok(cleaned !== null);
  assert.ok(cleaned.endsWith("…"), "Clamped text should end with ellipsis");
  assert.ok(cleaned.length <= 75, "Clamped text should respect character bounds");
});

test("MessageValidator enforces maximum 2 sentences", () => {
  const threeSentences = "You've been coding for 3 hours. Time for a quick break. Remember to stretch.";
  const cleaned = MessageValidator.sanitizeAndValidate(threeSentences);
  assert.equal(cleaned, "You've been coding for 3 hours. Time for a quick break.");
});

test("MessageValidator rejects pure generic motivational filler without context", () => {
  assert.equal(MessageValidator.sanitizeAndValidate("You got this!"), null);
  assert.equal(MessageValidator.sanitizeAndValidate("Believe in yourself!"), null);
  assert.equal(MessageValidator.sanitizeAndValidate("Keep pushing!"), null);
  assert.equal(MessageValidator.sanitizeAndValidate("You got this! Keep pushing!"), null);
});
