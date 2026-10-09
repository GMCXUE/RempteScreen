#!/usr/bin/env node
// 从媒体服务侧核查房间、参与者与已发布的轨道。
//
// 这是验证采集端是否真的把流发出去了的权威视角 —— 不看客户端自己的说法，
// 直接问媒体服务「房间里到底有什么」。
//
// 用法：
//   node inspect.mjs              列出所有房间
//   node inspect.mjs device-123456789   只看某个房间

import { twirp, signAdminToken } from './livekit-admin.mjs';

const targetRoom = process.argv[2];

const roomsResponse = await twirp('ListRooms');
if (!roomsResponse.ok) {
  console.error(`无法获取房间列表：HTTP ${roomsResponse.status} ${JSON.stringify(roomsResponse.body)}`);
  process.exit(1);
}

const rooms = roomsResponse.body.rooms ?? [];
if (rooms.length === 0) {
  console.log('当前没有任何活跃房间');
  process.exit(0);
}

const selected = targetRoom ? rooms.filter((room) => room.name === targetRoom) : rooms;
if (targetRoom && selected.length === 0) {
  console.log(`没有找到房间 ${targetRoom}`);
  console.log(`当前活跃房间：${rooms.map((room) => room.name).join(', ')}`);
  process.exit(0);
}

for (const room of selected) {
  const createdAt = room.creationTime
    ? new Date(Number(room.creationTime) * 1000).toISOString().slice(11, 19)
    : '未知';
  console.log(`房间 ${room.name}   创建于 ${createdAt} UTC   声明参与者 ${room.numParticipants ?? 0}`);

  // roomAdmin 是房间作用域的权限：令牌里必须同时带上 room 字段，
  // 否则 ListParticipants 会返回 401。这一点和 ListRooms 不同。
  const roomToken = signAdminToken({ roomAdmin: true, room: room.name });
  const participantsResponse = await twirp('ListParticipants', { room: room.name }, roomToken);
  if (!participantsResponse.ok) {
    console.log(`  无法获取参与者：HTTP ${participantsResponse.status}`);
    console.log('');
    continue;
  }

  const participants = participantsResponse.body.participants ?? [];
  if (participants.length === 0) {
    console.log('  （没有参与者）');
  }

  for (const participant of participants) {
    console.log(`  · ${participant.identity}   状态 ${participant.state}`);
    for (const track of participant.tracks ?? []) {
      const label = track.name || '(未命名)';
      console.log(`      - ${label}   type=${track.type}  source=${track.source}  muted=${track.muted}`);
    }
  }
  console.log('');
}
