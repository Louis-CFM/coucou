// What FCM's HTTP v1 answers mean for the box. Pure, so it is tested without a
// service account: https://firebase.google.com/docs/cloud-messaging/manage-tokens

/**
 * True when FCM says the token will never deliver again — the app was removed
 * or the token rotated. A 5xx, a quota answer or a malformed message is not
 * the token's fault and keeps it.
 */
export function tokenGone(status: number, body: string): boolean {
  return status === 404 || body.includes('"UNREGISTERED"');
}
