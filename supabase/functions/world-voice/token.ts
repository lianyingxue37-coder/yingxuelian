const utf8 = new TextEncoder();
const base64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes))
  .replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
const segment = (value: unknown) => base64url(utf8.encode(JSON.stringify(value)));

export async function worldVoiceToken(key: string, secret: string, uid: string) {
  const now = Math.floor(Date.now() / 1000);
  const body = {
    iss: key, sub: uid, nbf: now - 5, exp: now + 120, jti: crypto.randomUUID(),
    video: { roomJoin: true, room: 'duanlian-world', canSubscribe: true, canPublish: true,
      canPublishSources: ['microphone'], canPublishData: false },
  };
  const input = segment({ alg: 'HS256', typ: 'JWT' }) + '.' + segment(body);
  const signer = await crypto.subtle.importKey('raw', utf8.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', signer, utf8.encode(input));
  return input + '.' + base64url(new Uint8Array(signature));
}
