package com.remotescreen.remotescreen

import android.app.Application
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35], application=Application::class)
class ForegroundMessageTest {
    @Test fun bridgeCarriesSenderAndAvatarButRedactsAllPreviewFieldsWhenPrivate() {
        while(MessagingService.takeNotice()!=null) { /* drain previous test notices */ }
        val service=MessagingService()
        val emit=MessagingService::class.java.getDeclaredMethod("foregroundMessage",String::class.java,
            String::class.java,JSONObject::class.java,String::class.java,String::class.java,Boolean::class.javaPrimitiveType)
        emit.isAccessible=true
        val friend=JSONObject().put("avatarId","custom").put("avatarRevision","revision")
        emit.invoke(service,"me","peer",friend,"敏感昵称","敏感内容",true)
        val public=MessagingService.takeNotice()!!
        assertEquals("me",public["accountId"]);assertEquals("peer",public["peerId"])
        assertEquals("敏感昵称",public["name"]);assertEquals("敏感内容",public["message"])
        assertEquals("custom",public["avatarId"]);assertEquals("revision",public["avatarRevision"])
        assertEquals("true",public["preview"]);assertTrue(public["receivedAt"]!!.toLong()>0)
        emit.invoke(service,"me","peer",friend,"敏感昵称","敏感内容",false)
        val private=MessagingService.takeNotice()!!
        assertEquals("RemoteScreen",private["name"]);assertEquals("收到新消息",private["message"])
        assertEquals("false",private["preview"]);assertEquals("",private["avatarId"]);assertEquals("",private["avatarRevision"])
        assertFalse(private.toString().contains("敏感"));assertNull(MessagingService.takeNotice())
    }
}
