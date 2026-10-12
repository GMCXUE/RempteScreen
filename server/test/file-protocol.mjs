import test from 'node:test';
import assert from 'node:assert/strict';
import { signLiveKitToken, decodeTokenPayload } from '../src/token.mjs';
import { createRequest, listPendingForDevice, decideRequest, attachGrant, getRequest, cancelRequest } from '../src/requests.mjs';

test('file token grants data only in a separate room', () => {
  const payload = decodeTokenPayload(signLiveKitToken({
    identity: 'file-host-123456789', room: 'files-123456789',
    canPublish: false, canSubscribe: false, canPublishData: true,
  }));
  assert.equal(payload.video.room, 'files-123456789');
  assert.equal(payload.video.canPublish, false);
  assert.equal(payload.video.canSubscribe, false);
  assert.equal(payload.video.canPublishData, true);
  assert.equal(payload.video.canPublishSources, undefined);
});

test('existing screen tokens retain subscription permissions', () => {
  const payload = decodeTokenPayload(signLiveKitToken({
    identity: 'viewer', room: 'device-123456789', canPublish: true,
    canPublishSources: ['CAMERA', 'MICROPHONE'],
  }));
  assert.equal(payload.video.canSubscribe, true);
  assert.deepEqual(payload.video.canPublishSources, ['camera', 'microphone']);
});

test('invalid or empty source restrictions never silently grant unrestricted publishing', () => {
  for (const canPublishSources of [[], ['invalid']]) {
    assert.throws(() => signLiveKitToken({
      identity: 'viewer', room: 'device-123456789', canPublish: true, canPublishSources,
    }), TypeError);
  }
});

test('approval preserves explicit file purpose without relying on a display name', () => {
  const request = createRequest({deviceId: '123456780', viewerName: '普通名称', purpose: 'files'});
  const pending = listPendingForDevice('123456780');
  assert.equal(pending[0].purpose, 'files');
  decideRequest(request.id, true);
  attachGrant(request.id, {roomName: 'files-123456780', token: 'example'});
  assert.equal(getRequest(request.id).grant.roomName, 'files-123456780');
  assert.equal(listPendingForDevice('123456780').length, 0);
});

test('cancelled requests cannot be approved later', () => {
  const request = createRequest({deviceId: '123456781', viewerName: '文件传输'});
  assert.equal(request.purpose, 'screen');
  cancelRequest(request.id);
  decideRequest(request.id, true);
  assert.equal(getRequest(request.id).status, 'cancelled');
  assert.equal(listPendingForDevice('123456781').length, 0);
});
