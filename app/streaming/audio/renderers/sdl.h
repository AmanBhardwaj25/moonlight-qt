#pragma once

#include "renderer.h"
#include "SDL_compat.h"

#include <atomic>

class SdlAudioRenderer : public IAudioRenderer
{
public:
    SdlAudioRenderer();

    virtual ~SdlAudioRenderer();

    virtual bool prepareForPlayback(const OPUS_MULTISTREAM_CONFIGURATION* opusConfig);

    virtual void* getAudioBuffer(int* size);

    virtual bool submitAudio(int bytesWritten);

    virtual AudioFormat getAudioBufferFormat();

    static int getCurrentThresholdMs() { return s_CurrentThresholdMs.load(std::memory_order_relaxed); }
    static uint32_t getOverflowsLastWindow() { return s_OverflowsLastWindow.load(std::memory_order_relaxed); }
    // Returns true (once) when the threshold was just auto-increased; fills old/new values.
    static bool consumeThresholdIncrease(int& oldMs, int& newMs);
    // Returns true (once) when we hit 120ms and are still overflowing.
    static bool consumeMaxCapEvent();

private:
    SDL_AudioDeviceID m_AudioDevice;
    void* m_AudioBuffer;
    Uint32 m_FrameSize;
    Uint32 m_FrameDurationMs;
    int m_JitterBufferMs;
    Uint32 m_WindowStartMs;
    uint32_t m_WindowOverflows;

    static std::atomic<int> s_CurrentThresholdMs;
    static std::atomic<uint32_t> s_OverflowsLastWindow;
    static std::atomic<bool> s_ThresholdJustIncreased;
    static std::atomic<int> s_PreviousThresholdMs;
    static std::atomic<bool> s_AtMaxCapPending;
};
