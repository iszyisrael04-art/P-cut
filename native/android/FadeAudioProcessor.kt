package com.pcut.editor.p_cut

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/** Linear presentation-time envelope; Transformer prepends its speed processor. */
@UnstableApi
class FadeAudioProcessor(private val duration:Double,private val fadeIn:Double,private val fadeOut:Double):BaseAudioProcessor(){
  private var frames=0L
  override fun onConfigure(inputAudioFormat:AudioProcessor.AudioFormat):AudioProcessor.AudioFormat {
    if(inputAudioFormat.encoding!=C.ENCODING_PCM_16BIT && inputAudioFormat.encoding!=C.ENCODING_PCM_FLOAT)
      throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
    return inputAudioFormat
  }
  override fun onFlush(){frames=0}
  override fun queueInput(inputBuffer:ByteBuffer){
    val out=replaceOutputBuffer(inputBuffer.remaining())
    val bytes=if(inputAudioFormat.encoding==C.ENCODING_PCM_FLOAT)4 else 2
    val frameBytes=bytes*inputAudioFormat.channelCount
    while(inputBuffer.remaining()>=frameBytes){
      val t=frames.toDouble()/inputAudioFormat.sampleRate
      var gain=1.0
      if(fadeIn>0)gain*=(t/fadeIn).coerceIn(0.0,1.0)
      if(fadeOut>0)gain*=((duration-t)/fadeOut).coerceIn(0.0,1.0)
      repeat(inputAudioFormat.channelCount){
        if(bytes==4)out.putFloat((inputBuffer.float*gain).toFloat())
        else out.putShort((inputBuffer.short*gain).roundToInt().coerceIn(-32768,32767).toShort())
      }
      frames++
    }
    out.flip()
  }
}
