import { assertEquals } from 'jsr:@std/assert@1';
import { clientAddress } from './client_ip.ts';

const h = (o: Record<string, string>) => new Headers(o);

Deno.test('F-2: CF-Connecting-IP (set by Cloudflare) wins over a caller-written X-Forwarded-For', () => {
  assertEquals(clientAddress(h({ 'cf-connecting-ip': '68.65.164.215', 'x-forwarded-for': '9.9.9.9, 1.1.1.1' })), '68.65.164.215');
});

Deno.test('F-2: with CF-Connecting-IP, changing X-Forwarded-For does not change the client key', () => {
  const a = clientAddress(h({ 'cf-connecting-ip': '68.65.164.215', 'x-forwarded-for': '10.0.0.1' }));
  const b = clientAddress(h({ 'cf-connecting-ip': '68.65.164.215', 'x-forwarded-for': '10.0.0.2' }));
  assertEquals(a, b);
});

Deno.test('without CF-Connecting-IP: previous behaviour (first X-Forwarded-For), never a shared last hop', () => {
  assertEquals(clientAddress(h({ 'x-forwarded-for': '203.0.113.7, 10.1.0.1' })), '203.0.113.7');
  assertEquals(clientAddress(h({ 'x-forwarded-for': '203.0.113.8, 10.1.0.1' })), '203.0.113.8');
});

Deno.test('X-Real-IP fallback / nothing', () => {
  assertEquals(clientAddress(h({ 'x-real-ip': '203.0.113.8' })), '203.0.113.8');
  assertEquals(clientAddress(h({ 'x-forwarded-for': ' , ' })), null);
  assertEquals(clientAddress(h({})), null);
});

Deno.test('oversized header values are not used', () => {
  assertEquals(clientAddress(h({ 'cf-connecting-ip': 'x'.repeat(200), 'x-real-ip': '203.0.113.9' })), '203.0.113.9');
});
