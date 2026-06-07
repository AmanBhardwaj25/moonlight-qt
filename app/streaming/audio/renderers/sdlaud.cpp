#include "sdl.h"

#include <Limelight.h>
#include <algorithm>

std::atomic<int>      SdlAudioRenderer::s_CurrentThresholdMs{30};
std::atomic<uint32_t> SdlAudioRenderer::s_OverflowsLastWindow{0};
std::atomic<bool>     SdlAudioRenderer::s_ThresholdJustIncreased{false};
std::atomic<int>      SdlAudioRenderer::s_PreviousThresholdMs{30};
std::atomic<bool>     SdlAudioRenderer::s_AtMaxCapPending{false};

bool SdlAudioRenderer::consumeThresholdIncrease(int& oldMs, int& newMs)
{
    bool expected = true;
    if (s_ThresholdJustIncreased.compare_exchange_strong(expected, false, std::memory_order_acquire)) {
        oldMs = s_PreviousThresholdMs.load(std::memory_order_relaxed);
        newMs = s_CurrentThresholdMs.load(std::memory_order_relaxed);
        return true;
    }
    return false;
}

bool SdlAudioRenderer::consumeMaxCapEvent()
{
    bool expected = true;
    return s_AtMaxCapPending.compare_exchange_strong(expected, false, std::memory_order_acquire);
}

SdlAudioRenderer::SdlAudioRenderer()
    : m_AudioDevice(0),
      m_AudioBuffer(nullptr),
      m_JitterBufferMs(30),
      m_WindowStartMs(0),
      m_WindowOverflows(0)
{
    // Reset auto-tune state for this new session
    s_CurrentThresholdMs.store(30, std::memory_order_relaxed);
    s_OverflowsLastWindow.store(0, std::memory_order_relaxed);
    s_ThresholdJustIncreased.store(false, std::memory_order_relaxed);
    s_PreviousThresholdMs.store(30, std::memory_order_relaxed);
    s_AtMaxCapPending.store(false, std::memory_order_relaxed);

    SDL_assert(!SDL_WasInit(SDL_INIT_AUDIO));

    if (SDL_InitSubSystem(SDL_INIT_AUDIO) != 0) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "SDL_InitSubSystem(SDL_INIT_AUDIO) failed: %s",
                     SDL_GetError());
        SDL_assert(SDL_WasInit(SDL_INIT_AUDIO));
    }
}

bool SdlAudioRenderer::prepareForPlayback(const OPUS_MULTISTREAM_CONFIGURATION* opusConfig)
{
    SDL_AudioSpec want, have;

    SDL_zero(want);
    want.freq = opusConfig->sampleRate;
    want.format = AUDIO_F32SYS;
    want.channels = opusConfig->channelCount;

    // On PulseAudio systems, setting a value too small can cause underruns for other
    // applications sharing this output device. We impose a floor of 480 samples (10 ms)
    // to mitigate this issue. Otherwise, we will buffer up to 3 frames of audio which
    // is 15 ms at regular 5 ms frames and 30 ms at 10 ms frames for slow connections.
    // The buffering helps avoid audio underruns due to network jitter.
    want.samples = SDL_max(480, opusConfig->samplesPerFrame * 3);

    m_FrameDurationMs = opusConfig->samplesPerFrame / (opusConfig->sampleRate / 1000);
    m_FrameSize = opusConfig->samplesPerFrame *
                  opusConfig->channelCount *
                  getAudioBufferSampleSize();

    m_AudioDevice = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
    if (m_AudioDevice == 0) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "Failed to open audio device: %s",
                     SDL_GetError());
        return false;
    }

    m_AudioBuffer = SDL_malloc(m_FrameSize);
    if (m_AudioBuffer == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "Failed to allocate audio buffer");
        return false;
    }

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                "Desired audio buffer: %u samples (%u bytes)",
                want.samples,
                want.samples * want.channels * getAudioBufferSampleSize());

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                "Obtained audio buffer: %u samples (%u bytes)",
                have.samples,
                have.size);

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                "SDL audio driver: %s",
                SDL_GetCurrentAudioDriver());

    // Start playback
    SDL_PauseAudioDevice(m_AudioDevice, 0);

    return true;
}

SdlAudioRenderer::~SdlAudioRenderer()
{
    if (m_AudioDevice != 0) {
        // Stop playback
        SDL_PauseAudioDevice(m_AudioDevice, 1);
        SDL_CloseAudioDevice(m_AudioDevice);
    }

    if (m_AudioBuffer != nullptr) {
        SDL_free(m_AudioBuffer);
    }

    SDL_QuitSubSystem(SDL_INIT_AUDIO);
    SDL_assert(!SDL_WasInit(SDL_INIT_AUDIO));
}

void* SdlAudioRenderer::getAudioBuffer(int*)
{
    return m_AudioBuffer;
}

bool SdlAudioRenderer::submitAudio(int bytesWritten)
{
    if (bytesWritten == 0) {
        return true;
    }

    // Auto-tune: evaluate a 3-second window and increase the threshold if
    // overflows occurred, stepping up by 10ms per window up to 120ms.
    Uint32 now = SDL_GetTicks();
    if (m_WindowStartMs == 0) {
        m_WindowStartMs = now;
    }
    else if (now - m_WindowStartMs >= 3000) {
        s_OverflowsLastWindow.store(m_WindowOverflows, std::memory_order_relaxed);

        if (m_WindowOverflows > 0) {
            if (m_JitterBufferMs < 120) {
                int prev = m_JitterBufferMs;
                m_JitterBufferMs = std::min(m_JitterBufferMs + 10, 120);
                s_PreviousThresholdMs.store(prev, std::memory_order_relaxed);
                s_CurrentThresholdMs.store(m_JitterBufferMs, std::memory_order_relaxed);
                s_ThresholdJustIncreased.store(true, std::memory_order_relaxed);
            }
            else {
                s_AtMaxCapPending.store(true, std::memory_order_relaxed);
            }
        }

        m_WindowOverflows = 0;
        m_WindowStartMs = now;
    }

    if (LiGetPendingAudioDuration() > m_JitterBufferMs) {
        m_WindowOverflows++;
        return true;
    }

    // Provide backpressure on the queue to ensure too many frames don't build up
    // in SDL's audio queue, but don't wait forever to avoid a deadlock if the
    // audio device fails.
    for (int i = 0; i < 100; i++) {
        // Our device may enter a permanent error status upon removal, so we need
        // to recreate the audio device to pick up the new default audio device.
        if (SDL_GetAudioDeviceStatus(m_AudioDevice) == SDL_AUDIO_STOPPED) {
            return false;
        }

        // Only queue more samples where there is 50 ms or less in SDL's queue
        if (SDL_GetQueuedAudioSize(m_AudioDevice) / m_FrameSize * m_FrameDurationMs <= 50) {
            break;
        }

        SDL_Delay(1);
    }

    if (SDL_QueueAudio(m_AudioDevice, m_AudioBuffer, bytesWritten) < 0) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "Failed to queue audio sample: %s",
                     SDL_GetError());
    }

    return true;
}

IAudioRenderer::AudioFormat SdlAudioRenderer::getAudioBufferFormat()
{
    return AudioFormat::Float32NE;
}
