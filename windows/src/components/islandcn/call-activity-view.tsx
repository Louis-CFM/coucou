"use client";

import React, { useState } from "react";
import { type ActiveCall, acceptCall, declineCall, formatMMSS } from "./call-adapter";
import { HangUpGlyph, PhoneGlyph } from "./glyphs";
import { LevelMeter } from "./level-meter";
import { TickingTime } from "./ticking-time";
import { islandAccent } from "./theme";
import { initials } from "../../core/whatsapp";

const voiceEnvelope = [0.2, 0.55, 0.9, 1, 0.85, 0.65, 0.4, 0.35, 0.65, 0.85, 1, 0.95, 0.75, 0.45] as const;
const talkGreen = "#76fb73";
const meterTones = { near: talkGreen, far: islandAccent.orange, core: "#fffde0" } as const;

interface CallActivityViewProps {
  call: ActiveCall;
}

export const CallActivityView = React.memo(function CallActivityView({ call }: CallActivityViewProps) {
  const [imageError, setImageError] = useState(false);
  const isRinging = call.state === "ringing" || call.state === "accepting";
  const isActive = call.state === "active";
  const isEnded = call.state === "ended" || call.state === "declining" || call.state === "missed";

  const callerInitials = initials(call.caller);
  const showImage = Boolean(call.avatar && !imageError);

  const statusSubtitle = isRinging
    ? call.subtitle || "Incoming WhatsApp call"
    : isActive
      ? "WhatsApp Call"
      : call.state === "missed"
        ? "Missed Call"
        : "Call Ended";

  return (
    <div className={`coucou-call-activity-view state-${call.state}`}>
      {/* ── LEFT: Prominent Circular Caller Avatar ── */}
      <div className="coucou-call-lead">
        <div className="coucou-call-avatar-container">
          {showImage ? (
            <img
              src={call.avatar}
              alt={call.caller}
              className="coucou-call-avatar-img"
              onError={() => setImageError(true)}
            />
          ) : (
            <div className="coucou-call-avatar-fallback" aria-label={call.caller}>
              {callerInitials}
            </div>
          )}
        </div>
      </div>

      {/* ── CENTER: Caller Name & Call Telemetry ── */}
      <div className="coucou-call-body">
        {isActive ? (
          <>
            <div className="coucou-call-caller" title={call.caller}>
              {call.caller}
            </div>
            <div className="coucou-call-subtitle">
              <span className="coucou-call-elapsed">
                <TickingTime source={{ kind: "elapsed", since: call.since ?? Date.now() }} format={formatMMSS} />
              </span>
            </div>
          </>
        ) : (
          <>
            <div className="coucou-call-subtitle">{statusSubtitle}</div>
            <div className="coucou-call-caller" title={call.caller}>
              {call.caller}
            </div>
          </>
        )}
      </div>

      {/* ── RIGHT: Tactile Accept & Decline Actions ── */}
      <div className="coucou-call-trail">
        {isRinging && (
          <div className="coucou-call-buttons">
            {/* Decline Action */}
            <button
              type="button"
              className="coucou-call-btn btn-decline"
              title={`Decline call from ${call.caller}`}
              aria-label={`Decline call from ${call.caller}`}
              disabled={call.state === "declining"}
              onClick={(e) => {
                e.stopPropagation();
                void declineCall(call.id);
              }}
            >
              <HangUpGlyph size={24} />
            </button>

            {/* Accept Action */}
            <button
              type="button"
              className="coucou-call-btn btn-accept"
              title={`Accept call from ${call.caller}`}
              aria-label={`Accept call from ${call.caller}`}
              disabled={call.state === "accepting"}
              onClick={(e) => {
                e.stopPropagation();
                void acceptCall(call.id);
              }}
            >
              <PhoneGlyph size={24} />
            </button>
          </div>
        )}

        {isActive && (
          <div className="coucou-call-active-controls">
            <div className="coucou-call-meter-wrap">
              <LevelMeter
                envelope={voiceEnvelope}
                bars={7}
                colors={Array.from({ length: 7 }, (_, i) => (i < 4 ? meterTones.near : meterTones.far))}
                core={meterTones.core}
                height={13}
                barWidth={2}
                gap={1.5}
              />
            </div>
            <button
              type="button"
              className="coucou-call-btn btn-decline compact"
              title="End call"
              aria-label="End call"
              onClick={(e) => {
                e.stopPropagation();
                void declineCall(call.id);
              }}
            >
              <HangUpGlyph size={14} />
            </button>
          </div>
        )}

        {isEnded && (
          <div className="coucou-call-ended-indicator">
            <HangUpGlyph size={20} color="#fe4345" />
          </div>
        )}
      </div>
    </div>
  );
});
