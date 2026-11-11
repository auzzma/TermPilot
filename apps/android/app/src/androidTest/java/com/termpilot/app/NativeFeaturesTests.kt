package com.termpilot.app
import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.util.UUID

class NativeFeaturesTests {
 @Test fun appleMetadataExportDetectionPreservesOriginal() {
  val file=File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,"metadata-${UUID.randomUUID()}")
  try {
   file.writeText("content")
   assertFalse(AppleFileMetadata.needsConfirmation(file))
   Os.setxattr(file.path,"user.com.apple.FinderInfo",ByteArray(32){7},0)
   assertTrue(AppleFileMetadata.needsConfirmation(file))
   assertEquals("content",file.readText())
  }finally{file.delete()}
 }
 @Test fun shortcutOrderAndFunctionKeys() {
  val keys=TerminalKey.ordered("F12,Tab,invalid,F1,Tab")
  assertEquals(listOf("F12","Tab","F1"),keys.map{it.name})
  assertEquals("\u001b[24~",keys.first().text)
  assertEquals("\u001bOP",keys.last().text)
  assertEquals(0xffbe,keys.last().code)
 }
}
