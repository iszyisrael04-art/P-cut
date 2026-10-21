package com.pcut.editor.p_cut

import android.app.Activity
import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.PorterDuff
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.WindowManager
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.OverlaySettings
import androidx.media3.common.VideoCompositorSettings
import androidx.media3.common.util.Size
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.Brightness
import androidx.media3.effect.Contrast
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.RgbAdjustment
import androidx.media3.effect.RgbFilter
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.min
import kotlin.math.roundToInt

@UnstableApi
class CutRenderer(private val activity: Activity, messenger: BinaryMessenger) {
  private val channel = MethodChannel(messenger, "p_cut/render")
  private val handler = Handler(Looper.getMainLooper())
  private var transformer: Transformer? = null
  private var pending: MethodChannel.Result? = null
  private var output: File? = null
  private val bitmaps = mutableListOf<Bitmap>()
  init {
    channel.setMethodCallHandler { call, result ->
      when(call.method) {
        "progress" -> {
          val holder = ProgressHolder()
          if(transformer?.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) result.success(holder.progress/100.0)
          else result.success(0.0)
        }
        "cancel" -> {cancel();result.success(null)}
        "export" -> {
          if(pending != null) result.error("busy","Another export is running",null)
          else try {
            val args = call.arguments as Map<*, *>
            pending=result
            output=File(args["output"] as String)
            start(args["project"] as Map<*, *>, args["overlays"] as Map<*, *>, output!!.path)
          } catch(e:Exception) { fail(e.message ?: "Could not prepare export") }
        }
        "publish" -> {
          if(Build.VERSION.SDK_INT < 29) {result.error("unsupported","Saving to gallery requires Android 10 or later",null)}
          else {
            val path = call.argument<String>("path")
            Thread {
              var uri: Uri? = null
              try {
                val source=File(requireNotNull(path));require(source.isFile)
                val values=ContentValues().apply {
                  put(MediaStore.Video.Media.DISPLAY_NAME,source.name)
                  put(MediaStore.Video.Media.MIME_TYPE,"video/mp4")
                  put(MediaStore.Video.Media.RELATIVE_PATH,Environment.DIRECTORY_MOVIES+"/P-cut")
                  put(MediaStore.Video.Media.IS_PENDING,1)
                }
                uri=activity.contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI,values)
                val target=requireNotNull(uri)
                requireNotNull(activity.contentResolver.openOutputStream(target)).use { sink -> source.inputStream().use { it.copyTo(sink) } }
                values.clear();values.put(MediaStore.Video.Media.IS_PENDING,0)
                activity.contentResolver.update(target,values,null,null)
                handler.post { result.success("Saved to Movies/P-cut") }
              }catch(e:Exception){uri?.let{activity.contentResolver.delete(it,null,null)};handler.post{result.error("save",e.message,null)}}
            }.start()
          }
        }
        else -> result.notImplemented()
      }
    }
  }
  private fun number(m: Map<*, *>, key:String, default:Double=0.0)=(m[key] as? Number)?.toDouble() ?: default
  private fun gain(volume:Double): List<AudioProcessor> {
    val processor=ChannelMixingAudioProcessor()
    // Mono, stereo and multichannel phone recordings all receive the same gain.
    for(n in 1..8) processor.putChannelMixingMatrix(ChannelMixingMatrix.createForConstantGain(n,n).scaleBy(volume.toFloat()))
    return listOf(processor)
  }
  private fun motion(layer:Map<*, *>,time:Double):Map<String,Double>{
    val properties=listOf("x","y","size","opacity","rotation")
    fun values(m:Map<*, *>)=properties.associateWith{number(m,it,if(it=="opacity")1.0 else if(it=="x"||it=="y") .5 else if(it=="size") .12 else 0.0)}
    val keys=(layer["keys"] as? List<*>)?.map{it as Map<*, *>} ?: emptyList()
    if(keys.isEmpty())return values(layer)
    val t=(time-number(layer,"start")).coerceIn(0.0,number(layer,"end")-number(layer,"start"))
    if(t<=number(keys.first(),"time"))return values(keys.first())
    for(i in 1 until keys.size){val a=keys[i-1];val b=keys[i];if(t>number(b,"time"))continue
      var u=((t-number(a,"time"))/(number(b,"time")-number(a,"time"))).coerceIn(0.0,1.0)
      if(layer["easing"]=="smooth")u=u*u*(3-2*u)
      val va=values(a);val vb=values(b);return properties.associateWith{va[it]!!+(vb[it]!!-va[it]!!)*u}
    }
    return values(keys.last())
  }
  private fun start(project:Map<*, *>, overlays:Map<*, *>, path:String) {
    val clips=project["clips"] as List<*>
    require(clips.isNotEmpty() && clips.size<=100)
    val quality=(project["height"] as Number).toInt();require(quality in listOf(480,720,1080))
    val ratio=number(project,"ratio");require(ratio>0 && ratio<2)
    val height=if(ratio<1) (quality/ratio/2).roundToInt()*2 else quality
    val width=if(ratio<1) quality else (height*ratio/2).roundToInt()*2
    val main=EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO,C.TRACK_TYPE_VIDEO))
    val lengths=clips.map{raw -> val c=raw as Map<*, *>;(number(c,"end")-number(c,"start"))/number(c,"speed",1.0)}
    val overlaps=lengths.indices.map{i -> if(i==lengths.lastIndex)0.0 else number(clips[i] as Map<*, *>,"transition").coerceIn(0.0,min(lengths[i],lengths[i+1])/2)}
    val starts=mutableListOf<Double>();var total=0.0
    for(i in lengths.indices){starts.add(total);total+=lengths[i]-overlaps[i]}
    val transitioning=overlaps.any{it>0}
    val items=mutableListOf<EditedMediaItem>()
    for((index,raw) in clips.withIndex()) {
      val c=raw as Map<*, *>;val image=c["kind"]=="image"
      val speed=number(c,"speed",1.0);require(speed in listOf(.25,.5,1.0,1.5,2.0,3.0,4.0))
      val start=number(c,"start");val end=number(c,"end");require(end>start && start>=0)
      val seconds=(end-start)/speed
      val media=MediaItem.Builder().setUri(Uri.fromFile(File(c["path"] as String)))
      if(image)media.setImageDurationMs((seconds*1000).toLong())
      else media.setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setStartPositionMs((start*1000).toLong()).setEndPositionMs((end*1000).toLong()).build())
      val effects=mutableListOf<Effect>()
      val rotation=number(c,"rotation").toInt()
      if(rotation!=0)effects.add(ScaleAndRotateTransformation.Builder().setRotationDegrees(-90f*rotation).build())
      effects.add(Presentation.createForWidthAndHeight(width,height,if(c["fit"]=="cover") Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP else Presentation.LAYOUT_SCALE_TO_FIT))
      val contrast=number(c,"contrast")
      effects.add(Contrast((contrast/(2.0+contrast)).toFloat()))
      effects.add(Brightness(number(c,"brightness").toFloat()))
      when(c["filter"]){
        "mono" -> effects.add(RgbFilter.createGrayscaleFilter())
        "warm" -> effects.add(RgbAdjustment.Builder().setRedScale(1.12f).setBlueScale(.88f).build())
        "cool" -> effects.add(RgbAdjustment.Builder().setRedScale(.88f).setBlueScale(1.12f).build())
      }
      val builder=EditedMediaItem.Builder(media.build()).setFrameRate(30).setEffects(Effects(gain(number(c,"volume",1.0))+listOf(FadeAudioProcessor(seconds,if(index>0)overlaps[index-1] else 0.0,overlaps[index])),effects))
      if(image)builder.setRemoveAudio(true)
      else if(speed!=1.0)builder.setSpeed(object:SpeedProvider {
        override fun getSpeed(timeUs:Long)=speed.toFloat()
        override fun getNextSpeedChangeTimeUs(timeUs:Long)=C.TIME_UNSET
      })
      val edited=builder.build();main.addItem(edited);items.add(edited)
    }
    require(total<=1800)
    val sequences=mutableListOf<EditedMediaItemSequence>()
    if(transitioning){
      for(lane in 0..1){
        val sequence=EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO,C.TRACK_TYPE_VIDEO));var cursor=0.0
        for(i in items.indices){if(i%2!=lane)continue
          val gap=starts[i]-cursor;if(gap>.000001)sequence.addGap((gap*1000000).toLong())
          sequence.addItem(items[i]);cursor=starts[i]+lengths[i]
        }
        if(total-cursor>.000001)sequence.addGap(((total-cursor)*1000000).toLong())
        sequences.add(sequence.build())
      }
    }else sequences.add(main.build())
    for(raw in project["audio"] as List<*>) {
      val a=raw as Map<*, *>;val start=number(a,"start");if(start>=total)continue
      val duration=min(number(a,"length"),total-start);if(duration<=0)continue
      val input=number(a,"inPoint")
      val item=MediaItem.Builder().setUri(Uri.fromFile(File(a["path"] as String))).setClippingConfiguration(
        MediaItem.ClippingConfiguration.Builder().setStartPositionMs((input*1000).toLong()).setEndPositionMs(((input+duration)*1000).toLong()).build()).build()
      val sequence=EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
      if(start>0)sequence.addGap((start*1000000).toLong())
      sequence.addItem(EditedMediaItem.Builder(item).setRemoveVideo(true).setEffects(Effects(gain(number(a,"volume",.5))+listOf(FadeAudioProcessor(number(a,"length"),number(a,"fadeIn"),number(a,"fadeOut"))),emptyList())).build())
      val remaining=total-start-duration;if(remaining>.001)sequence.addGap((remaining*1000000).toLong())
      sequences.add(sequence.build())
    }
    val layers=project["layers"] as List<*>;require(layers.size<=12)
    val graphics=layers.map { raw ->
      val layer=raw as Map<*, *>;val bitmap=requireNotNull(BitmapFactory.decodeFile(overlays[layer["id"]] as String))
      bitmaps.add(bitmap)
      object:BitmapOverlay(){
        override fun getBitmap(presentationTimeUs:Long):Bitmap=bitmap
        override fun getOverlaySettings(presentationTimeUs:Long):OverlaySettings {
          val time=presentationTimeUs/1000000.0
          val active=time>=number(layer,"start") && time<number(layer,"end")
          val value=motion(layer,time)
          val peak=((layer["keys"] as? List<*>)?:emptyList<Any>()).fold(number(layer,"size",.12)){maximum,key -> maxOf(maximum,number(key as Map<*, *>,"size",.12))}
          val scale=value["size"]!!/peak
          return StaticOverlaySettings.Builder().setAlphaScale(if(active)value["opacity"]!!.toFloat() else 0f)
            .setBackgroundFrameAnchor((2*value["x"]!!-1).toFloat(),(1-2*value["y"]!!).toFloat())
            .setScale(scale.toFloat(),scale.toFloat()).setRotationDegrees(-value["rotation"]!!.toFloat()).build()
        }
      }
    }
    val captions=(project["captions"] as? List<*>)?.map{it as Map<*, *>} ?: emptyList()
    require(captions.size<=500)
    val allGraphics=graphics.toMutableList<BitmapOverlay>()
    if(captions.isNotEmpty()){
      val image=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888);bitmaps.add(image)
      allGraphics.add(object:BitmapOverlay(){
        private var lastId:String?=null
        override fun getBitmap(presentationTimeUs:Long):Bitmap {
          val t=presentationTimeUs/1000000.0
          val cue=captions.firstOrNull{t>=number(it,"start") && t<number(it,"end")}
          val id=cue?.get("id") as? String
          if(id!=lastId){
            val canvas=Canvas(image);canvas.drawColor(Color.TRANSPARENT,PorterDuff.Mode.CLEAR)
            if(id!=null){val source=requireNotNull(BitmapFactory.decodeFile(overlays["caption:$id"] as String));canvas.drawBitmap(source,0f,0f,null);source.recycle()}
            lastId=id
          }
          return image
        }
      })
    }
    val compositionBuilder=Composition.Builder(sequences)
    if(transitioning)compositionBuilder.setVideoCompositorSettings(object:VideoCompositorSettings {
      override fun getOutputSize(inputSizes:MutableList<Size>)=Size(width,height)
      override fun getOverlaySettings(inputId:Int,presentationTimeUs:Long):OverlaySettings {
        val t=presentationTimeUs/1000000.0
        val index=items.indices.firstOrNull{it%2==inputId && t>=starts[it] && t<starts[it]+lengths[it]}
        var alpha=if(index==null)0.0 else 1.0
        // Input 0 is the foreground. The background stays opaque during an overlap.
        if(inputId==0 && index!=null){
          val local=t-starts[index];val incoming=if(index>0)overlaps[index-1] else 0.0
          if(incoming>0)alpha*=(local/incoming).coerceIn(0.0,1.0)
          if(overlaps[index]>0)alpha*=((lengths[index]-local)/overlaps[index]).coerceIn(0.0,1.0)
        }
        return StaticOverlaySettings.Builder().setAlphaScale(alpha.toFloat()).build()
      }
    })
    val composition=compositionBuilder.setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL).setEffects(Effects(emptyList(),if(allGraphics.isEmpty())emptyList() else listOf(OverlayEffect(allGraphics)))).build()
    activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    val worker=Transformer.Builder(activity).setVideoMimeType(MimeTypes.VIDEO_H264).setAudioMimeType(MimeTypes.AUDIO_AAC)
      .addListener(object:Transformer.Listener {
        override fun onCompleted(composition:Composition,exportResult:ExportResult){
          val result=pending;pending=null;transformer=null;releaseImages();result?.success(path)
        }
        override fun onError(composition:Composition,exportResult:ExportResult,exportException:ExportException){fail(exportException.message ?: "Export failed")}
      }).build()
    transformer=worker;worker.start(composition,path)
  }
  private fun releaseImages(){activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);bitmaps.forEach{if(!it.isRecycled)it.recycle()};bitmaps.clear()}
  private fun fail(message:String){transformer?.cancel();transformer=null;output?.delete();releaseImages();val result=pending;pending=null;result?.error("export",message,null)}
  private fun cancel(){if(pending!=null)fail("Export cancelled")}
  fun dispose(){cancel();channel.setMethodCallHandler(null)}
}
