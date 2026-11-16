"use client";

import { DesktopGlyph, type IslandGlyph, LaptopGlyph, PhoneDeviceGlyph, TabletGlyph } from "./glyphs";
import { MediaLead, MediaText, MediaTrail, mediaRow, SharePicture, ShareRing } from "./media-row";
import { IconRing } from "./progress-ring";
import { islandAccent } from "./theme";
import { useActivity, useLatest } from "./use-activity";

import {
  nearbyTransferWords,
  type NearbyDevice,
  type NearbyTransferWords,
} from "./transfer-adapter";

export { nearbyTransferWords, type NearbyDevice, type NearbyTransferWords };

export interface NearbyTransferActivityProps {
  /** Activity id. Defaults to "nearby-transfer". */
  id?: string;
  /** Higher priority takes the main pill when two activities run. Defaults to 0. */
  priority?: number;
  /** Sending to the device, or receiving from it. Defaults to "send". */
  direction?: "send" | "receive";
  /** The other device's or person's name, such as "Maya's Laptop". */
  deviceName: string;
  /** What kind of device it is. Picks the glyph when there is no `avatar`. Defaults to "phone". */
  device?: NearbyDevice;
  /** What is moving, such as "biscuit-in-the-sun.jpg" or "3 photos", in the grey line of the expanded view ("Sending 3 photos"). */
  itemName: string;
  /** A thumbnail of what is moving, set on the corner of the device as a badge. Defaults to none (no badge). */
  src?: string;
  /** The other person's photo, in place of the device. Defaults to none (the device's glyph in the accent). */
  avatar?: string;
  /** Progress from 0 to 1. At 1 it shows a check and "Sent" or "Received". */
  progress: number;
  /** Accent colour of the device disc, the ring and the check. Defaults to blue. */
  accent?: string;
  /** Makes the expanded ring a stop button while it runs. Defaults to none (the ring shows an arrow for the direction). */
  onCancel?: () => void;
}

const deviceGlyphs = {
  phone: PhoneDeviceGlyph,
  tablet: TabletGlyph,
  laptop: LaptopGlyph,
  desktop: DesktopGlyph,
} as const satisfies Record<NearbyDevice, IslandGlyph>;



/**
 * A transfer to or from a device nearby, as a nearby share shows one. Compact shows who it goes
 * to and a ring that fills; expanded is one row: the device (or the person) with the photo being
 * sent on its corner, "Sending biscuit-in-the-sun.jpg" in grey over "To Maya's Laptop", and the
 * ring large, with a stop square when it can be cancelled. Receiving reads "From …" with the
 * arrow down. At 1 the ring turns into a check and the line into "Sent …" or "Received …".
 */
export const NearbyTransferActivity = ({
  id = "nearby-transfer", priority = 0,
  direction = "send",
  deviceName,
  device = "phone",
  itemName,
  src,
  avatar,
  progress,
  accent = islandAccent.blue,
  onCancel,
}: NearbyTransferActivityProps) => {
  const cancel = useLatest(onCancel);
  const hasCancel = onCancel !== undefined;
  const value = Math.min(1, Math.max(0, progress));
  const percent = Math.floor(value * 100);
  const done = value >= 1;

  useActivity(() => {
    const glyph = deviceGlyphs[device];
    const sending = direction === "send";
    const { label, action, party } = nearbyTransferWords({ direction, deviceName, itemName, progress: value });
    const person = avatar === undefined ? undefined : { name: deviceName, src: avatar };
    const ring = <ShareRing value={value} accent={accent} />;
    // When the split doesn't fit at all, the device in its ring. In the split's bubble the compact pair fits whole (a 22 pt disc and a 20 pt ring).
    const minimal = done ? ring : <IconRing icon={glyph} value={value} accent={accent} size={22} />;
    return {
      id,
      priority,
      label,
      compact: { leading: <SharePicture icon={glyph} accent={accent} person={person} />, trailing: ring },
      minimal,
      expanded: {
        leading: (
          <MediaLead>
            <SharePicture icon={glyph} accent={accent} person={person} size={mediaRow.lead} src={src} />
          </MediaLead>
        ),
        center: <MediaText line={action} title={party} />,
        trailing: (
          <MediaTrail>
            <ShareRing
              value={value}
              accent={accent}
              size={mediaRow.ring}
              mark={hasCancel ? "stop" : sending ? "up" : "down"}
              onStop={hasCancel ? () => cancel.current?.() : undefined}
              stopLabel={`Stop ${sending ? "sending to" : "receiving from"} ${deviceName}`}
            />
          </MediaTrail>
        ),
        bottom: undefined,
      },
    };
  }, [id, priority, direction, deviceName, device, itemName, src, avatar, percent, done, accent, hasCancel]);

  return null;
};
