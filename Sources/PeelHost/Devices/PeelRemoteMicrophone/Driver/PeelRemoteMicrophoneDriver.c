#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "PeelRemoteMicrophoneIO.h"
#include "PeelRemoteMicrophoneProducer.h"
#include "ProducerAuthentication.h"
#include "ProducerLifecycle.h"
#include "ProducerProtocol.h"

#if ATOMIC_INT_LOCK_FREE != 2
#error "PeelRemoteMicrophoneDriver requires always-lock-free unsigned int atomics"
#endif

enum {
    kPeelObjectID_PlugIn = kAudioObjectPlugInObject,
    kPeelObjectID_Device = 2,
    kPeelObjectID_InputStream = 3
};

enum {
    kPeelSampleRate = PEEL_AUDIO_RING_SAMPLE_RATE_HZ,
    kPeelChannelCount = PEEL_AUDIO_RING_CHANNEL_COUNT,
    kPeelZeroTimeStampPeriodFrames = 480,
    kPeelReadScratchFrames = 480,
    kPeelMaximumRegisteredClients = 64
};

#define kPeelDeviceUID "com.zephyrstudiosllc.PeelRemoteMicrophone.Device.v1"
#define kPeelModelUID "com.zephyrstudiosllc.PeelRemoteMicrophone.Model.v1"

static const CFStringRef kPeelDeviceName = CFSTR("Peel Remote Microphone");
static const CFStringRef kPeelStreamName = CFSTR("Peel Remote Microphone Input");
static const CFStringRef kPeelManufacturer = CFSTR("Zephyr Studios");

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gProducerControlMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static bool gInitialized = false;
static UInt32 gRegisteredClients[kPeelMaximumRegisteredClients];
static size_t gRegisteredClientCount = 0u;

typedef struct PeelProducerSession {
    bool active;
    pid_t owner_process_id;
    uint64_t generation;
    uint8_t token[PEEL_PRODUCER_TOKEN_BYTES];
    bool has_sequence;
    uint64_t last_sequence;
    PeelProducerPCMDisposition last_disposition;
    uint64_t enqueued_packets;
    uint64_t discarded_waiting_packets;
    uint64_t rejected_overflow_packets;
    uint64_t rejected_sequence_packets;
} PeelProducerSession;

static PeelProducerSession gProducerSession;
static bool gHasRetiredProducerToken = false;
static uint8_t gRetiredProducerToken[PEEL_PRODUCER_TOKEN_BYTES];
static PeelProducerLifecycle gProducerLifecycle;
static PeelAudioRing gAudioRing;
static int16_t gReadScratch[kPeelReadScratchFrames];

static atomic_uint gReferenceCount = ATOMIC_VAR_INIT(1u);
static atomic_uint gInputStreamIsActive = ATOMIC_VAR_INIT(1u);
static atomic_uint gIOIsRunning = ATOMIC_VAR_INIT(0u);
static atomic_uint gIOOwnerClientID = ATOMIC_VAR_INIT(0u);
static atomic_uint gProducerAcceptingFrames = ATOMIC_VAR_INIT(0u);
static atomic_uint gProducerCallsInFlight = ATOMIC_VAR_INIT(0u);
static atomic_uint gConsumerCallInFlight = ATOMIC_VAR_INIT(0u);
static atomic_ullong gProducerSessionSequence = ATOMIC_VAR_INIT(0u);
static atomic_ullong gProducerGeneration = ATOMIC_VAR_INIT(0u);
static atomic_ullong gTimelineSequence = ATOMIC_VAR_INIT(0u);
static atomic_ullong gTimelineSeed = ATOMIC_VAR_INIT(0u);
static atomic_ullong gTimelineAnchorHostTime = ATOMIC_VAR_INIT(0u);
static atomic_ullong gHostTicksPerZeroTimeStamp = ATOMIC_VAR_INIT(0u);
static atomic_ullong gRenderedFrameCount = ATOMIC_VAR_INIT(0u);

static HRESULT Peel_QueryInterface(
    void *inDriver,
    REFIID inUUID,
    LPVOID *outInterface
);
static ULONG Peel_AddRef(void *inDriver);
static ULONG Peel_Release(void *inDriver);
static OSStatus Peel_Initialize(
    AudioServerPlugInDriverRef inDriver,
    AudioServerPlugInHostRef inHost
);
static OSStatus Peel_CreateDevice(
    AudioServerPlugInDriverRef inDriver,
    CFDictionaryRef inDescription,
    const AudioServerPlugInClientInfo *inClientInfo,
    AudioObjectID *outDeviceObjectID
);
static OSStatus Peel_DestroyDevice(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID
);
static OSStatus Peel_AddDeviceClient(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    const AudioServerPlugInClientInfo *inClientInfo
);
static OSStatus Peel_RemoveDeviceClient(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    const AudioServerPlugInClientInfo *inClientInfo
);
static OSStatus Peel_PerformDeviceConfigurationChange(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction,
    void *inChangeInfo
);
static OSStatus Peel_AbortDeviceConfigurationChange(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction,
    void *inChangeInfo
);
static Boolean Peel_HasProperty(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress
);
static OSStatus Peel_IsPropertySettable(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    Boolean *outIsSettable
);
static OSStatus Peel_GetPropertyDataSize(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 *outDataSize
);
static OSStatus Peel_GetPropertyData(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData
);
static OSStatus Peel_SetPropertyData(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 inDataSize,
    const void *inData
);
static OSStatus Peel_StartIO(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID
);
static OSStatus Peel_StopIO(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID
);
static OSStatus Peel_GetZeroTimeStamp(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID,
    Float64 *outSampleTime,
    UInt64 *outHostTime,
    UInt64 *outSeed
);
static OSStatus Peel_WillDoIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    Boolean *outWillDo,
    Boolean *outWillDoInPlace
);
static OSStatus Peel_BeginIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo *inIOCycleInfo
);
static OSStatus Peel_DoIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    AudioObjectID inStreamObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
    void *ioMainBuffer,
    void *ioSecondaryBuffer
);
static OSStatus Peel_EndIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo *inIOCycleInfo
);
static unsigned long long Peel_NextNonzeroCounter(
    atomic_ullong *inCounter
);

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    Peel_QueryInterface,
    Peel_AddRef,
    Peel_Release,
    Peel_Initialize,
    Peel_CreateDevice,
    Peel_DestroyDevice,
    Peel_AddDeviceClient,
    Peel_RemoveDeviceClient,
    Peel_PerformDeviceConfigurationChange,
    Peel_AbortDeviceConfigurationChange,
    Peel_HasProperty,
    Peel_IsPropertySettable,
    Peel_GetPropertyDataSize,
    Peel_GetPropertyData,
    Peel_SetPropertyData,
    Peel_StartIO,
    Peel_StopIO,
    Peel_GetZeroTimeStamp,
    Peel_WillDoIOOperation,
    Peel_BeginIOOperation,
    Peel_DoIOOperation,
    Peel_EndIOOperation
};

static AudioServerPlugInDriverInterface *gDriverInterfacePointer =
    &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePointer;

__attribute__((visibility("default")))
void *PeelRemoteMicrophone_Create(
    CFAllocatorRef inAllocator,
    CFUUIDRef inRequestedTypeUUID
) {
    (void)inAllocator;
    if (inRequestedTypeUUID != NULL &&
        CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

static bool Peel_IsDriverReference(AudioServerPlugInDriverRef inDriver) {
    return inDriver == gDriverRef;
}

static bool Peel_IsKnownObject(AudioObjectID inObjectID) {
    return inObjectID == kPeelObjectID_PlugIn ||
        inObjectID == kPeelObjectID_Device ||
        inObjectID == kPeelObjectID_InputStream;
}

static bool Peel_ScopeIncludesInput(AudioObjectPropertyScope inScope) {
    return inScope == kAudioObjectPropertyScopeGlobal ||
        inScope == kAudioObjectPropertyScopeInput;
}

static bool Peel_ClientIsRegisteredLocked(UInt32 inClientID) {
    for (size_t index = 0u; index < gRegisteredClientCount; ++index) {
        if (gRegisteredClients[index] == inClientID) {
            return true;
        }
    }
    return false;
}

static OSStatus Peel_CopyPropertyValue(
    const void *inValue,
    UInt32 inValueSize,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData
) {
    if (outDataSize == NULL || (inValueSize > 0u && outData == NULL)) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inDataSize < inValueSize) {
        return kAudioHardwareBadPropertySizeError;
    }
    if (inValueSize > 0u) {
        memcpy(outData, inValue, inValueSize);
    }
    *outDataSize = inValueSize;
    return noErr;
}

static OSStatus Peel_GetCFDataBytes(
    UInt32 inValueSize,
    const void *inValue,
    const uint8_t **outBytes,
    size_t *outByteCount
) {
    if (inValueSize != sizeof(CFPropertyListRef)) {
        return kAudioHardwareBadPropertySizeError;
    }
    if (inValue == NULL || outBytes == NULL || outByteCount == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    const CFPropertyListRef propertyList =
        *((const CFPropertyListRef *)inValue);
    if (propertyList == NULL ||
        CFGetTypeID(propertyList) != CFDataGetTypeID()) {
        return kAudioHardwareIllegalOperationError;
    }

    const CFDataRef data = (CFDataRef)propertyList;
    const CFIndex length = CFDataGetLength(data);
    if (length < 0 || (uintmax_t)length > (uintmax_t)SIZE_MAX) {
        return kAudioHardwareBadPropertySizeError;
    }

    *outBytes = CFDataGetBytePtr(data);
    *outByteCount = (size_t)length;
    if (*outByteCount > 0u && *outBytes == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    return noErr;
}

static bool Peel_TokensEqual(
    const uint8_t lhs[PEEL_PRODUCER_TOKEN_BYTES],
    const uint8_t rhs[PEEL_PRODUCER_TOKEN_BYTES]
) {
    uint8_t difference = 0u;
    for (size_t index = 0u; index < PEEL_PRODUCER_TOKEN_BYTES; ++index) {
        difference |= (uint8_t)(lhs[index] ^ rhs[index]);
    }
    return difference == 0u;
}

static void Peel_IncrementSaturating(uint64_t *value) {
    if (*value != UINT64_MAX) {
        ++(*value);
    }
}

static void Peel_ClearProducerSessionLocked(void) {
    peel_producer_lifecycle_invalidate(&gProducerLifecycle);
    if (gProducerSession.active) {
        memcpy(
            gRetiredProducerToken,
            gProducerSession.token,
            PEEL_PRODUCER_TOKEN_BYTES
        );
        gHasRetiredProducerToken = true;
    }
    memset(&gProducerSession, 0, sizeof(gProducerSession));
}

static bool Peel_ProducerSessionIsAuthorizedLocked(
    pid_t inClientProcessID,
    const uint8_t token[PEEL_PRODUCER_TOKEN_BYTES]
) {
    return inClientProcessID > 0 &&
        gProducerSession.active &&
        gProducerSession.owner_process_id == inClientProcessID &&
        Peel_TokensEqual(gProducerSession.token, token);
}

static OSStatus Peel_BeginProducerSession(
    pid_t inClientProcessID,
    const uint8_t *bytes,
    size_t byteCount
) {
    uint8_t token[PEEL_PRODUCER_TOKEN_BYTES];
    if (peel_producer_protocol_parse_begin(bytes, byteCount, token) !=
        PEEL_PRODUCER_PROTOCOL_OK) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inClientProcessID <= 0) {
        return kAudioDevicePermissionsError;
    }

    OSStatus status = noErr;
    pthread_mutex_lock(&gProducerControlMutex);
    if (!peel_producer_authenticate_process(inClientProcessID)) {
        status = kAudioDevicePermissionsError;
    } else {
        if (gProducerSession.active &&
            peel_producer_process_has_exited(
                gProducerSession.owner_process_id
            )) {
            Peel_ClearProducerSessionLocked();
        }

        if (gProducerSession.active) {
            status = kAudioHardwareIllegalOperationError;
        } else if (
            gHasRetiredProducerToken &&
            Peel_TokensEqual(gRetiredProducerToken, token)
        ) {
            status = kAudioHardwareIllegalOperationError;
        } else {
            Peel_ClearProducerSessionLocked();
            const uint64_t generation = (uint64_t)
                Peel_NextNonzeroCounter(&gProducerSessionSequence);
            gProducerSession.active = true;
            gProducerSession.owner_process_id = inClientProcessID;
            gProducerSession.generation = generation;
            memcpy(
                gProducerSession.token,
                token,
                PEEL_PRODUCER_TOKEN_BYTES
            );
            if (!peel_producer_lifecycle_publish(
                    &gProducerLifecycle,
                    generation
                )) {
                Peel_ClearProducerSessionLocked();
                status = kAudioHardwareIllegalOperationError;
            }
        }
    }
    pthread_mutex_unlock(&gProducerControlMutex);
    memset(token, 0, sizeof(token));
    return status;
}

static OSStatus Peel_EndProducerSession(
    pid_t inClientProcessID,
    const uint8_t *bytes,
    size_t byteCount
) {
    uint8_t token[PEEL_PRODUCER_TOKEN_BYTES];
    if (peel_producer_protocol_parse_end(bytes, byteCount, token) !=
        PEEL_PRODUCER_PROTOCOL_OK) {
        return kAudioHardwareIllegalOperationError;
    }

    OSStatus status = noErr;
    pthread_mutex_lock(&gProducerControlMutex);
    if (!Peel_ProducerSessionIsAuthorizedLocked(
            inClientProcessID,
            token
        )) {
        status = kAudioDevicePermissionsError;
    } else {
        Peel_ClearProducerSessionLocked();
    }
    pthread_mutex_unlock(&gProducerControlMutex);
    memset(token, 0, sizeof(token));
    return status;
}

static OSStatus Peel_SubmitProducerPCM(
    pid_t inClientProcessID,
    const uint8_t *bytes,
    size_t byteCount
) {
    PeelProducerPCMRequest request;
    if (peel_producer_protocol_parse_pcm(bytes, byteCount, &request) !=
        PEEL_PRODUCER_PROTOCOL_OK) {
        return kAudioHardwareIllegalOperationError;
    }

    OSStatus status = noErr;
    pthread_mutex_lock(&gProducerControlMutex);
    if (!Peel_ProducerSessionIsAuthorizedLocked(
            inClientProcessID,
            request.token
        )) {
        status = kAudioDevicePermissionsError;
    } else if (!peel_producer_protocol_sequence_is_new(
                   gProducerSession.has_sequence,
                   gProducerSession.last_sequence,
                   request.sequence
               )) {
        Peel_IncrementSaturating(
            &gProducerSession.rejected_sequence_packets
        );
        gProducerSession.last_disposition =
            PEEL_PRODUCER_PCM_REJECTED_SEQUENCE;
        status = kAudioHardwareIllegalOperationError;
    } else {
        const uint64_t ioGeneration =
            peel_remote_microphone_driver_producer_generation();
        const uint64_t producerSessionGeneration =
            gProducerSession.generation;
        if (ioGeneration == 0u ||
            !peel_producer_lifecycle_session_is_ready(
                &gProducerLifecycle,
                producerSessionGeneration
            )) {
            gProducerSession.has_sequence = true;
            gProducerSession.last_sequence = request.sequence;
            Peel_IncrementSaturating(
                &gProducerSession.discarded_waiting_packets
            );
            gProducerSession.last_disposition =
                PEEL_PRODUCER_PCM_DISCARDED_WAITING;
        } else {
            const PeelAudioRingStatus ringStatus =
                peel_remote_microphone_driver_enqueue_frames(
                    ioGeneration,
                    producerSessionGeneration,
                    request.frames,
                    PEEL_PRODUCER_PCM_FRAME_COUNT
                );
            if (ringStatus == PEEL_AUDIO_RING_OK) {
                gProducerSession.has_sequence = true;
                gProducerSession.last_sequence = request.sequence;
                Peel_IncrementSaturating(
                    &gProducerSession.enqueued_packets
                );
                gProducerSession.last_disposition =
                    PEEL_PRODUCER_PCM_ENQUEUED;
            } else if (ringStatus == PEEL_AUDIO_RING_OVERFLOW) {
                Peel_IncrementSaturating(
                    &gProducerSession.rejected_overflow_packets
                );
                gProducerSession.last_disposition =
                    PEEL_PRODUCER_PCM_REJECTED_OVERFLOW;
                status = kAudioHardwareIllegalOperationError;
            } else {
                status = kAudioHardwareIllegalOperationError;
            }
        }
    }
    pthread_mutex_unlock(&gProducerControlMutex);
    memset(&request, 0, sizeof(request));
    return status;
}

static OSStatus Peel_CopyProducerStatus(
    pid_t inClientProcessID,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData
) {
    if (inDataSize < sizeof(CFPropertyListRef)) {
        return kAudioHardwareBadPropertySizeError;
    }
    if (outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    const uint8_t *qualifierBytes = NULL;
    size_t qualifierByteCount = 0u;
    OSStatus status = Peel_GetCFDataBytes(
        inQualifierDataSize,
        inQualifierData,
        &qualifierBytes,
        &qualifierByteCount
    );
    if (status != noErr) {
        return status;
    }

    uint8_t token[PEEL_PRODUCER_TOKEN_BYTES];
    if (peel_producer_protocol_parse_status_qualifier(
            qualifierBytes,
            qualifierByteCount,
            token
        ) != PEEL_PRODUCER_PROTOCOL_OK) {
        return kAudioHardwareIllegalOperationError;
    }

    uint8_t response[PEEL_PRODUCER_STATUS_RESPONSE_BYTES];
    pthread_mutex_lock(&gProducerControlMutex);
    if (!Peel_ProducerSessionIsAuthorizedLocked(
            inClientProcessID,
            token
        )) {
        status = kAudioDevicePermissionsError;
    } else {
        const PeelProducerStatusSnapshot snapshot = {
            .session_state =
                (
                    peel_remote_microphone_driver_producer_generation() ==
                        0u ||
                    !peel_producer_lifecycle_session_is_ready(
                        &gProducerLifecycle,
                        gProducerSession.generation
                    )
                )
                    ? PEEL_PRODUCER_SESSION_WAITING_FOR_CONSUMER
                    : PEEL_PRODUCER_SESSION_READY,
            .last_disposition = gProducerSession.last_disposition,
            .enqueued_packets = gProducerSession.enqueued_packets,
            .discarded_waiting_packets =
                gProducerSession.discarded_waiting_packets,
            .rejected_overflow_packets =
                gProducerSession.rejected_overflow_packets,
            .rejected_sequence_packets =
                gProducerSession.rejected_sequence_packets
        };
        if (peel_producer_protocol_encode_status(
                &snapshot,
                response
            ) != PEEL_PRODUCER_PROTOCOL_OK) {
            status = kAudioHardwareIllegalOperationError;
        }
    }
    pthread_mutex_unlock(&gProducerControlMutex);
    memset(token, 0, sizeof(token));
    if (status != noErr) {
        memset(response, 0, sizeof(response));
        return status;
    }

    CFDataRef responseData = CFDataCreate(
        kCFAllocatorDefault,
        response,
        (CFIndex)sizeof(response)
    );
    memset(response, 0, sizeof(response));
    if (responseData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    *((CFPropertyListRef *)outData) = responseData;
    *outDataSize = (UInt32)sizeof(CFPropertyListRef);
    return noErr;
}

static OSStatus Peel_AuthorizeProducerStatusSize(
    pid_t inClientProcessID,
    UInt32 inQualifierDataSize,
    const void *inQualifierData
) {
    const uint8_t *qualifierBytes = NULL;
    size_t qualifierByteCount = 0u;
    OSStatus status = Peel_GetCFDataBytes(
        inQualifierDataSize,
        inQualifierData,
        &qualifierBytes,
        &qualifierByteCount
    );
    if (status != noErr) {
        return status;
    }

    uint8_t token[PEEL_PRODUCER_TOKEN_BYTES];
    if (peel_producer_protocol_parse_status_qualifier(
            qualifierBytes,
            qualifierByteCount,
            token
        ) != PEEL_PRODUCER_PROTOCOL_OK) {
        return kAudioHardwareIllegalOperationError;
    }

    pthread_mutex_lock(&gProducerControlMutex);
    const bool authorized = Peel_ProducerSessionIsAuthorizedLocked(
        inClientProcessID,
        token
    );
    pthread_mutex_unlock(&gProducerControlMutex);
    memset(token, 0, sizeof(token));
    return authorized ? noErr : kAudioDevicePermissionsError;
}

static OSStatus Peel_SetProducerProperty(
    pid_t inClientProcessID,
    AudioObjectPropertySelector inSelector,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 inDataSize,
    const void *inData
) {
    if (inQualifierDataSize != 0u || inQualifierData != NULL) {
        return kAudioHardwareBadPropertySizeError;
    }

    const uint8_t *bytes = NULL;
    size_t byteCount = 0u;
    OSStatus status = Peel_GetCFDataBytes(
        inDataSize,
        inData,
        &bytes,
        &byteCount
    );
    if (status != noErr) {
        return status;
    }

    switch (inSelector) {
        case PEEL_PRODUCER_PROPERTY_BEGIN:
            return Peel_BeginProducerSession(
                inClientProcessID,
                bytes,
                byteCount
            );
        case PEEL_PRODUCER_PROPERTY_END:
            return Peel_EndProducerSession(
                inClientProcessID,
                bytes,
                byteCount
            );
        case PEEL_PRODUCER_PROPERTY_PCM:
            return Peel_SubmitProducerPCM(
                inClientProcessID,
                bytes,
                byteCount
            );
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Peel_CopyObjectList(
    const AudioObjectID *inObjects,
    UInt32 inObjectCount,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData
) {
    UInt32 requestedCount = inDataSize / (UInt32)sizeof(AudioObjectID);
    if (requestedCount > inObjectCount) {
        requestedCount = inObjectCount;
    }
    return Peel_CopyPropertyValue(
        inObjects,
        requestedCount * (UInt32)sizeof(AudioObjectID),
        inDataSize,
        outDataSize,
        outData
    );
}

static AudioStreamBasicDescription Peel_StreamFormat(void) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = (Float64)kPeelSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags =
        kAudioFormatFlagIsFloat |
        kAudioFormatFlagsNativeEndian |
        kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = (UInt32)sizeof(Float32);
    format.mFramesPerPacket = 1u;
    format.mBytesPerFrame = (UInt32)sizeof(Float32);
    format.mChannelsPerFrame = kPeelChannelCount;
    format.mBitsPerChannel = 8u * (UInt32)sizeof(Float32);
    return format;
}

static void Peel_BeginTimelineMutationLocked(void) {
    (void)atomic_fetch_add_explicit(
        &gTimelineSequence,
        1u,
        memory_order_acq_rel
    );
}

static void Peel_EndTimelineMutationLocked(void) {
    (void)atomic_fetch_add_explicit(
        &gTimelineSequence,
        1u,
        memory_order_release
    );
}

static unsigned long long Peel_NextNonzeroCounter(
    atomic_ullong *inCounter
) {
    unsigned long long value = atomic_fetch_add_explicit(
        inCounter,
        1u,
        memory_order_acq_rel
    ) + 1u;
    if (value == 0u) {
        value = atomic_fetch_add_explicit(
            inCounter,
            1u,
            memory_order_acq_rel
        ) + 1u;
    }
    return value;
}

static void Peel_EndIOOwnershipLocked(void) {
    atomic_store_explicit(
        &gProducerAcceptingFrames,
        0u,
        memory_order_release
    );
    (void)Peel_NextNonzeroCounter(&gProducerGeneration);

    Peel_BeginTimelineMutationLocked();
    atomic_store_explicit(&gIOIsRunning, 0u, memory_order_release);
    atomic_store_explicit(&gIOOwnerClientID, 0u, memory_order_relaxed);
    Peel_EndTimelineMutationLocked();

    if (atomic_load_explicit(
            &gProducerCallsInFlight,
            memory_order_acquire
        ) == 0u &&
        atomic_load_explicit(
            &gConsumerCallInFlight,
            memory_order_acquire
        ) == 0u) {
        (void)peel_audio_ring_reset_quiescent(&gAudioRing);
    }
}

uint64_t peel_remote_microphone_driver_producer_generation(void) {
    if (atomic_load_explicit(
            &gProducerAcceptingFrames,
            memory_order_acquire
        ) == 0u ||
        atomic_load_explicit(&gIOIsRunning, memory_order_acquire) == 0u) {
        return 0u;
    }

    return (uint64_t)atomic_load_explicit(
        &gProducerGeneration,
        memory_order_acquire
    );
}

PeelAudioRingStatus peel_remote_microphone_driver_enqueue_frames(
    uint64_t io_generation,
    uint64_t producer_session_generation,
    const int16_t *frames,
    size_t frame_count
) {
    if (frames == NULL) {
        return PEEL_AUDIO_RING_INVALID_ARGUMENT;
    }
    if (frame_count == 0u ||
        frame_count > PEEL_AUDIO_RING_CAPACITY_FRAMES) {
        return PEEL_AUDIO_RING_INVALID_SIZE;
    }
    if (io_generation == 0u ||
        producer_session_generation == 0u ||
        !peel_producer_lifecycle_session_is_ready(
            &gProducerLifecycle,
            producer_session_generation
        ) ||
        atomic_load_explicit(
            &gProducerAcceptingFrames,
            memory_order_acquire
        ) == 0u ||
        atomic_load_explicit(
            &gProducerGeneration,
            memory_order_acquire
        ) != (unsigned long long)io_generation) {
        return PEEL_AUDIO_RING_INVALID_STATE;
    }

    unsigned int expectedProducerCalls = 0u;
    if (!atomic_compare_exchange_strong_explicit(
            &gProducerCallsInFlight,
            &expectedProducerCalls,
            1u,
            memory_order_acq_rel,
            memory_order_acquire
        )) {
        return PEEL_AUDIO_RING_INVALID_STATE;
    }

    PeelAudioRingStatus status;
    if (atomic_load_explicit(
            &gProducerAcceptingFrames,
            memory_order_acquire
        ) == 0u ||
        atomic_load_explicit(
            &gProducerGeneration,
            memory_order_acquire
        ) != (unsigned long long)io_generation ||
        !peel_producer_lifecycle_session_is_ready(
            &gProducerLifecycle,
            producer_session_generation
        )) {
        status = PEEL_AUDIO_RING_INVALID_STATE;
    } else {
        status = peel_audio_ring_write(&gAudioRing, frames, frame_count);
    }

    atomic_store_explicit(
        &gProducerCallsInFlight,
        0u,
        memory_order_release
    );
    return status;
}

/*
 * Called only by the HAL ring consumer while gConsumerCallInFlight is held.
 * A barrier callback always emits silence. It drains no more than the logical
 * ring capacity, then acknowledges the generation only if no old producer
 * write can still publish data.
 */
static bool Peel_PrepareProducerAudioForRead(
    uint64_t *outProducerSessionGeneration
) {
    if (outProducerSessionGeneration == NULL) {
        return false;
    }

    const uint64_t publishedGeneration =
        peel_producer_lifecycle_published(&gProducerLifecycle);
    const uint64_t readyGeneration =
        peel_producer_lifecycle_consumer_ready(&gProducerLifecycle);
    if (publishedGeneration == readyGeneration) {
        *outProducerSessionGeneration = publishedGeneration;
        return publishedGeneration != 0u;
    }

    if (atomic_load_explicit(
            &gProducerCallsInFlight,
            memory_order_acquire
        ) != 0u) {
        return false;
    }

    size_t framesRemaining = PEEL_AUDIO_RING_CAPACITY_FRAMES;
    while (framesRemaining > 0u) {
        const size_t framesThisRead =
            framesRemaining < kPeelReadScratchFrames
                ? framesRemaining
                : kPeelReadScratchFrames;
        const PeelAudioRingReadResult result = peel_audio_ring_read(
            &gAudioRing,
            gReadScratch,
            framesThisRead
        );
        if ((result.status != PEEL_AUDIO_RING_OK &&
             result.status != PEEL_AUDIO_RING_UNDERRUN) ||
            result.frames_read > framesThisRead) {
            return false;
        }
        framesRemaining -= result.frames_read;
        if (result.frames_read < framesThisRead) {
            break;
        }
    }

    if (atomic_load_explicit(
            &gProducerCallsInFlight,
            memory_order_acquire
        ) != 0u) {
        return false;
    }
    (void)peel_producer_lifecycle_consumer_acknowledge(
        &gProducerLifecycle,
        publishedGeneration
    );
    return false;
}

static HRESULT Peel_QueryInterface(
    void *inDriver,
    REFIID inUUID,
    LPVOID *outInterface
) {
    if (inDriver != gDriverRef || outInterface == NULL) {
        return E_NOINTERFACE;
    }

    *outInterface = NULL;
    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requestedUUID == NULL) {
        return E_NOINTERFACE;
    }

    const bool supported =
        CFEqual(requestedUUID, IUnknownUUID) ||
        CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requestedUUID);

    if (!supported) {
        return E_NOINTERFACE;
    }

    *outInterface = gDriverRef;
    (void)Peel_AddRef(inDriver);
    return S_OK;
}

static ULONG Peel_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) {
        return 0u;
    }

    unsigned int current = atomic_load_explicit(
        &gReferenceCount,
        memory_order_relaxed
    );
    while (current != UINT32_MAX &&
           !atomic_compare_exchange_weak_explicit(
               &gReferenceCount,
               &current,
               current + 1u,
               memory_order_relaxed,
               memory_order_relaxed
           )) {
    }
    return (ULONG)current + (current == UINT32_MAX ? 0u : 1u);
}

static ULONG Peel_Release(void *inDriver) {
    if (inDriver != gDriverRef) {
        return 0u;
    }

    unsigned int current = atomic_load_explicit(
        &gReferenceCount,
        memory_order_relaxed
    );
    while (current > 0u &&
           !atomic_compare_exchange_weak_explicit(
               &gReferenceCount,
               &current,
               current - 1u,
               memory_order_relaxed,
               memory_order_relaxed
           )) {
    }
    return (ULONG)(current > 0u ? current - 1u : 0u);
}

static OSStatus Peel_Initialize(
    AudioServerPlugInDriverRef inDriver,
    AudioServerPlugInHostRef inHost
) {
    if (!Peel_IsDriverReference(inDriver)) {
        return kAudioHardwareBadObjectError;
    }
    if (inHost == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    OSStatus status = noErr;
    pthread_mutex_lock(&gStateMutex);
    if (!gInitialized) {
        mach_timebase_info_data_t timebase;
        if (mach_timebase_info(&timebase) != KERN_SUCCESS ||
            timebase.numer == 0u) {
            status = kAudioHardwareIllegalOperationError;
        } else if (peel_audio_ring_init(&gAudioRing) !=
                   PEEL_AUDIO_RING_OK) {
            status = kAudioHardwareIllegalOperationError;
        } else {
            const uint64_t nanosecondsPerPeriod = 10000000u;
            const uint64_t ticksPerPeriod =
                (
                    nanosecondsPerPeriod * (uint64_t)timebase.denom +
                    ((uint64_t)timebase.numer / 2u)
                ) / (uint64_t)timebase.numer;
            if (ticksPerPeriod == 0u) {
                status = kAudioHardwareIllegalOperationError;
            } else {
                atomic_store_explicit(
                    &gHostTicksPerZeroTimeStamp,
                    (unsigned long long)ticksPerPeriod,
                    memory_order_relaxed
                );
                peel_producer_lifecycle_init(&gProducerLifecycle);
                gInitialized = true;
            }
        }
    }
    if (status == noErr) {
        gHost = inHost;
    }
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

static OSStatus Peel_CreateDevice(
    AudioServerPlugInDriverRef inDriver,
    CFDictionaryRef inDescription,
    const AudioServerPlugInClientInfo *inClientInfo,
    AudioObjectID *outDeviceObjectID
) {
    (void)inDescription;
    (void)inClientInfo;
    (void)outDeviceObjectID;
    return Peel_IsDriverReference(inDriver)
        ? kAudioHardwareUnsupportedOperationError
        : kAudioHardwareBadObjectError;
}

static OSStatus Peel_DestroyDevice(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID
) {
    (void)inDeviceObjectID;
    return Peel_IsDriverReference(inDriver)
        ? kAudioHardwareUnsupportedOperationError
        : kAudioHardwareBadObjectError;
}

static OSStatus Peel_AddDeviceClient(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    const AudioServerPlugInClientInfo *inClientInfo
) {
    if (!Peel_IsDriverReference(inDriver) ||
        inDeviceObjectID != kPeelObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    if (inClientInfo == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    OSStatus status = noErr;
    pthread_mutex_lock(&gStateMutex);
    if (!Peel_ClientIsRegisteredLocked(inClientInfo->mClientID)) {
        if (gRegisteredClientCount >= kPeelMaximumRegisteredClients) {
            status = kAudioHardwareIllegalOperationError;
        } else {
            gRegisteredClients[gRegisteredClientCount] =
                inClientInfo->mClientID;
            ++gRegisteredClientCount;
        }
    }
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

static OSStatus Peel_RemoveDeviceClient(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    const AudioServerPlugInClientInfo *inClientInfo
) {
    if (!Peel_IsDriverReference(inDriver) ||
        inDeviceObjectID != kPeelObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    if (inClientInfo == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    pthread_mutex_lock(&gStateMutex);
    for (size_t index = 0u; index < gRegisteredClientCount; ++index) {
        if (gRegisteredClients[index] == inClientInfo->mClientID) {
            if (atomic_load_explicit(
                    &gIOIsRunning,
                    memory_order_acquire
                ) != 0u &&
                atomic_load_explicit(
                    &gIOOwnerClientID,
                    memory_order_relaxed
                ) == inClientInfo->mClientID) {
                Peel_EndIOOwnershipLocked();
            }

            --gRegisteredClientCount;
            gRegisteredClients[index] =
                gRegisteredClients[gRegisteredClientCount];
            break;
        }
    }
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus Peel_PerformDeviceConfigurationChange(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction,
    void *inChangeInfo
) {
    (void)inChangeAction;
    (void)inChangeInfo;
    if (!Peel_IsDriverReference(inDriver) ||
        inDeviceObjectID != kPeelObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Peel_AbortDeviceConfigurationChange(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction,
    void *inChangeInfo
) {
    (void)inChangeAction;
    (void)inChangeInfo;
    if (!Peel_IsDriverReference(inDriver) ||
        inDeviceObjectID != kPeelObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return noErr;
}

static Boolean Peel_PlugInHasProperty(
    const AudioObjectPropertyAddress *inAddress
) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case PEEL_PRODUCER_PROPERTY_BEGIN:
        case PEEL_PRODUCER_PROPERTY_END:
        case PEEL_PRODUCER_PROPERTY_PCM:
        case PEEL_PRODUCER_PROPERTY_STATUS:
            return true;
        default:
            return false;
    }
}

static Boolean Peel_DeviceHasProperty(
    const AudioObjectPropertyAddress *inAddress
) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyStreamConfiguration:
            return true;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            return inAddress->mScope == kAudioObjectPropertyScopeInput;
        default:
            return false;
    }
}

static Boolean Peel_StreamHasProperty(
    const AudioObjectPropertyAddress *inAddress
) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static Boolean Peel_HasProperty(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress
) {
    (void)inClientProcessID;
    if (!Peel_IsDriverReference(inDriver) || inAddress == NULL) {
        return false;
    }

    switch (inObjectID) {
        case kPeelObjectID_PlugIn:
            return Peel_PlugInHasProperty(inAddress);
        case kPeelObjectID_Device:
            return Peel_DeviceHasProperty(inAddress);
        case kPeelObjectID_InputStream:
            return Peel_StreamHasProperty(inAddress);
        default:
            return false;
    }
}

static OSStatus Peel_IsPropertySettable(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    Boolean *outIsSettable
) {
    if (!Peel_IsDriverReference(inDriver) || !Peel_IsKnownObject(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == NULL || outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!Peel_HasProperty(
            inDriver,
            inObjectID,
            inClientProcessID,
            inAddress
        )) {
        return kAudioHardwareUnknownPropertyError;
    }

    *outIsSettable =
        (
            inObjectID == kPeelObjectID_InputStream &&
            inAddress->mSelector == kAudioStreamPropertyIsActive
        ) ||
        (
            inObjectID == kPeelObjectID_PlugIn &&
            (
                inAddress->mSelector == PEEL_PRODUCER_PROPERTY_BEGIN ||
                inAddress->mSelector == PEEL_PRODUCER_PROPERTY_END ||
                inAddress->mSelector == PEEL_PRODUCER_PROPERTY_PCM
            )
        );
    return noErr;
}

static OSStatus Peel_GetPlugInPropertyDataSize(
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 *outDataSize
) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = (UInt32)sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = (UInt32)sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = (UInt32)sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = (UInt32)sizeof(AudioObjectID);
            return noErr;
        case kAudioPlugInPropertyBoxList:
            *outDataSize = 0u;
            return noErr;
        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize =
                4u * (UInt32)sizeof(AudioServerPlugInCustomPropertyInfo);
            return noErr;
        case PEEL_PRODUCER_PROPERTY_BEGIN:
        case PEEL_PRODUCER_PROPERTY_END:
        case PEEL_PRODUCER_PROPERTY_PCM:
            *outDataSize = (UInt32)sizeof(CFPropertyListRef);
            return noErr;
        case PEEL_PRODUCER_PROPERTY_STATUS: {
            const OSStatus status = Peel_AuthorizeProducerStatusSize(
                inClientProcessID,
                inQualifierDataSize,
                inQualifierData
            );
            if (status != noErr) {
                return status;
            }
            *outDataSize = (UInt32)sizeof(CFPropertyListRef);
            return noErr;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static UInt32 Peel_DeviceInputObjectCount(
    const AudioObjectPropertyAddress *inAddress
) {
    return Peel_ScopeIncludesInput(inAddress->mScope) ? 1u : 0u;
}

static OSStatus Peel_GetDevicePropertyDataSize(
    const AudioObjectPropertyAddress *inAddress,
    UInt32 *outDataSize
) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = (UInt32)sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            *outDataSize = (UInt32)sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = (UInt32)sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            *outDataSize =
                Peel_DeviceInputObjectCount(inAddress) *
                (UInt32)sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyControlList:
            *outDataSize = 0u;
            return noErr;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = (UInt32)sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = (UInt32)sizeof(AudioObjectID);
            return noErr;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = (UInt32)sizeof(Float64);
            return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = (UInt32)sizeof(AudioValueRange);
            return noErr;
        case kAudioDevicePropertyStreamConfiguration:
            *outDataSize =
                (UInt32)offsetof(AudioBufferList, mBuffers) +
                Peel_DeviceInputObjectCount(inAddress) *
                    (UInt32)sizeof(AudioBuffer);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Peel_GetStreamPropertyDataSize(
    const AudioObjectPropertyAddress *inAddress,
    UInt32 *outDataSize
) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = (UInt32)sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            *outDataSize = (UInt32)sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyName:
            *outDataSize = (UInt32)sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0u;
            return noErr;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = (UInt32)sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize =
                (UInt32)sizeof(AudioStreamBasicDescription);
            return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize =
                (UInt32)sizeof(AudioStreamRangedDescription);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Peel_GetPropertyDataSize(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 *outDataSize
) {
    if (!Peel_IsDriverReference(inDriver) || !Peel_IsKnownObject(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == NULL || outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!Peel_HasProperty(
            inDriver,
            inObjectID,
            inClientProcessID,
            inAddress
        )) {
        return kAudioHardwareUnknownPropertyError;
    }

    switch (inObjectID) {
        case kPeelObjectID_PlugIn:
            return Peel_GetPlugInPropertyDataSize(
                inClientProcessID,
                inAddress,
                inQualifierDataSize,
                inQualifierData,
                outDataSize
            );
        case kPeelObjectID_Device:
            return Peel_GetDevicePropertyDataSize(inAddress, outDataSize);
        case kPeelObjectID_InputStream:
            return Peel_GetStreamPropertyDataSize(inAddress, outDataSize);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus Peel_GetPlugInPropertyData(
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData
) {
    const AudioObjectID deviceObject = kPeelObjectID_Device;
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: {
            const AudioClassID value = kAudioObjectClassID;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioObjectPropertyClass: {
            const AudioClassID value = kAudioPlugInClassID;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioObjectPropertyOwner: {
            const AudioObjectID value = kAudioObjectUnknown;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioObjectPropertyManufacturer:
            return Peel_CopyPropertyValue(
                &kPeelManufacturer,
                (UInt32)sizeof(kPeelManufacturer),
                inDataSize,
                outDataSize,
                outData
            );
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            return Peel_CopyObjectList(
                &deviceObject,
                1u,
                inDataSize,
                outDataSize,
                outData
            );
        case kAudioPlugInPropertyBoxList:
            *outDataSize = 0u;
            return noErr;
        case kAudioPlugInPropertyTranslateUIDToBox: {
            if (inQualifierDataSize != sizeof(CFStringRef) ||
                inQualifierData == NULL) {
                return kAudioHardwareBadPropertySizeError;
            }
            const AudioObjectID value = kAudioObjectUnknown;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inQualifierDataSize != sizeof(CFStringRef) ||
                inQualifierData == NULL) {
                return kAudioHardwareBadPropertySizeError;
            }
            const CFStringRef uid =
                *((const CFStringRef *)inQualifierData);
            const AudioObjectID value =
                uid != NULL &&
                CFStringCompare(uid, CFSTR(kPeelDeviceUID), 0) ==
                    kCFCompareEqualTo
                    ? kPeelObjectID_Device
                    : kAudioObjectUnknown;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioPlugInPropertyResourceBundle: {
            const CFStringRef value = CFSTR("");
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            const AudioServerPlugInCustomPropertyInfo values[] = {
                {
                    PEEL_PRODUCER_PROPERTY_BEGIN,
                    kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                    kAudioServerPlugInCustomPropertyDataTypeNone
                },
                {
                    PEEL_PRODUCER_PROPERTY_END,
                    kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                    kAudioServerPlugInCustomPropertyDataTypeNone
                },
                {
                    PEEL_PRODUCER_PROPERTY_PCM,
                    kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                    kAudioServerPlugInCustomPropertyDataTypeNone
                },
                {
                    PEEL_PRODUCER_PROPERTY_STATUS,
                    kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                    kAudioServerPlugInCustomPropertyDataTypeCFPropertyList
                }
            };
            return Peel_CopyPropertyValue(
                values,
                (UInt32)sizeof(values),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case PEEL_PRODUCER_PROPERTY_STATUS:
            return Peel_CopyProducerStatus(
                inClientProcessID,
                inQualifierDataSize,
                inQualifierData,
                inDataSize,
                outDataSize,
                outData
            );
        case PEEL_PRODUCER_PROPERTY_BEGIN:
        case PEEL_PRODUCER_PROPERTY_END:
        case PEEL_PRODUCER_PROPERTY_PCM:
            return kAudioHardwareUnsupportedOperationError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Peel_GetStreamConfiguration(
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData
) {
    const UInt32 bufferCount = Peel_DeviceInputObjectCount(inAddress);
    const UInt32 requiredSize =
        (UInt32)offsetof(AudioBufferList, mBuffers) +
        bufferCount * (UInt32)sizeof(AudioBuffer);
    if (inDataSize < requiredSize) {
        return kAudioHardwareBadPropertySizeError;
    }
    if (outData == NULL || outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    AudioBufferList *bufferList = (AudioBufferList *)outData;
    bufferList->mNumberBuffers = bufferCount;
    if (bufferCount == 1u) {
        bufferList->mBuffers[0].mNumberChannels = kPeelChannelCount;
        bufferList->mBuffers[0].mDataByteSize = 0u;
        bufferList->mBuffers[0].mData = NULL;
    }
    *outDataSize = requiredSize;
    return noErr;
}

static OSStatus Peel_GetDevicePropertyData(
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData
) {
    const AudioObjectID inputStream = kPeelObjectID_InputStream;
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: {
            const AudioClassID value = kAudioObjectClassID;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioObjectPropertyClass: {
            const AudioClassID value = kAudioDeviceClassID;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioObjectPropertyOwner: {
            const AudioObjectID value = kPeelObjectID_PlugIn;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioObjectPropertyName:
            return Peel_CopyPropertyValue(
                &kPeelDeviceName,
                (UInt32)sizeof(kPeelDeviceName),
                inDataSize,
                outDataSize,
                outData
            );
        case kAudioObjectPropertyManufacturer:
            return Peel_CopyPropertyValue(
                &kPeelManufacturer,
                (UInt32)sizeof(kPeelManufacturer),
                inDataSize,
                outDataSize,
                outData
            );
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            return Peel_CopyObjectList(
                &inputStream,
                Peel_DeviceInputObjectCount(inAddress),
                inDataSize,
                outDataSize,
                outData
            );
        case kAudioObjectPropertyControlList:
            *outDataSize = 0u;
            return noErr;
        case kAudioDevicePropertyDeviceUID: {
            const CFStringRef value = CFSTR(kPeelDeviceUID);
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioDevicePropertyModelUID: {
            const CFStringRef value = CFSTR(kPeelModelUID);
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioDevicePropertyTransportType: {
            const UInt32 value = kAudioDeviceTransportTypeVirtual;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioDevicePropertyRelatedDevices: {
            const AudioObjectID value = kPeelObjectID_Device;
            return Peel_CopyObjectList(
                &value,
                1u,
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset: {
            const UInt32 value = 0u;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: {
            const UInt32 value = 1u;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioDevicePropertyDeviceIsRunning: {
            const UInt32 value = atomic_load_explicit(
                &gIOIsRunning,
                memory_order_acquire
            );
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioDevicePropertyNominalSampleRate: {
            const Float64 value = (Float64)kPeelSampleRate;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            const AudioValueRange value = {
                .mMinimum = (Float64)kPeelSampleRate,
                .mMaximum = (Float64)kPeelSampleRate
            };
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioDevicePropertyZeroTimeStampPeriod: {
            const UInt32 value = kPeelZeroTimeStampPeriodFrames;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioDevicePropertyStreamConfiguration:
            return Peel_GetStreamConfiguration(
                inAddress,
                inDataSize,
                outDataSize,
                outData
            );
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Peel_GetStreamPropertyData(
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData
) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: {
            const AudioClassID value = kAudioObjectClassID;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioObjectPropertyClass: {
            const AudioClassID value = kAudioStreamClassID;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioObjectPropertyOwner: {
            const AudioObjectID value = kPeelObjectID_Device;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioObjectPropertyName:
            return Peel_CopyPropertyValue(
                &kPeelStreamName,
                (UInt32)sizeof(kPeelStreamName),
                inDataSize,
                outDataSize,
                outData
            );
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0u;
            return noErr;
        case kAudioStreamPropertyIsActive: {
            const UInt32 value = atomic_load_explicit(
                &gInputStreamIsActive,
                memory_order_acquire
            );
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioStreamPropertyDirection: {
            const UInt32 value = 1u;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioStreamPropertyTerminalType: {
            const UInt32 value = kAudioStreamTerminalTypeMicrophone;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioStreamPropertyStartingChannel: {
            const UInt32 value = 1u;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioStreamPropertyLatency: {
            const UInt32 value = 0u;
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            const AudioStreamBasicDescription value = Peel_StreamFormat();
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            const AudioStreamRangedDescription value = {
                .mFormat = Peel_StreamFormat(),
                .mSampleRateRange = {
                    .mMinimum = (Float64)kPeelSampleRate,
                    .mMaximum = (Float64)kPeelSampleRate
                }
            };
            return Peel_CopyPropertyValue(
                &value,
                (UInt32)sizeof(value),
                inDataSize,
                outDataSize,
                outData
            );
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Peel_GetPropertyData(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData
) {
    (void)inClientProcessID;
    if (!Peel_IsDriverReference(inDriver) || !Peel_IsKnownObject(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == NULL || outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!Peel_HasProperty(
            inDriver,
            inObjectID,
            inClientProcessID,
            inAddress
        )) {
        return kAudioHardwareUnknownPropertyError;
    }

    switch (inObjectID) {
        case kPeelObjectID_PlugIn:
            return Peel_GetPlugInPropertyData(
                inClientProcessID,
                inAddress,
                inQualifierDataSize,
                inQualifierData,
                inDataSize,
                outDataSize,
                outData
            );
        case kPeelObjectID_Device:
            return Peel_GetDevicePropertyData(
                inAddress,
                inDataSize,
                outDataSize,
                outData
            );
        case kPeelObjectID_InputStream:
            return Peel_GetStreamPropertyData(
                inAddress,
                inDataSize,
                outDataSize,
                outData
            );
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus Peel_SetPropertyData(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 inDataSize,
    const void *inData
) {
    if (!Peel_IsDriverReference(inDriver) || !Peel_IsKnownObject(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }
    if (inAddress == NULL || inData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    if (inObjectID == kPeelObjectID_PlugIn &&
        (
            inAddress->mSelector == PEEL_PRODUCER_PROPERTY_BEGIN ||
            inAddress->mSelector == PEEL_PRODUCER_PROPERTY_END ||
            inAddress->mSelector == PEEL_PRODUCER_PROPERTY_PCM
        )) {
        return Peel_SetProducerProperty(
            inClientProcessID,
            inAddress->mSelector,
            inQualifierDataSize,
            inQualifierData,
            inDataSize,
            inData
        );
    }

    if (inObjectID != kPeelObjectID_InputStream ||
        inAddress->mSelector != kAudioStreamPropertyIsActive) {
        return Peel_HasProperty(
            inDriver,
            inObjectID,
            inClientProcessID,
            inAddress
        )
            ? kAudioHardwareUnsupportedOperationError
            : kAudioHardwareUnknownPropertyError;
    }
    if (inDataSize != sizeof(UInt32)) {
        return kAudioHardwareBadPropertySizeError;
    }

    const UInt32 newValue = *((const UInt32 *)inData) != 0u ? 1u : 0u;
    const UInt32 oldValue = atomic_exchange_explicit(
        &gInputStreamIsActive,
        newValue,
        memory_order_acq_rel
    );
    if (oldValue != newValue && gHost != NULL) {
        const AudioObjectPropertyAddress changedAddress = {
            kAudioStreamPropertyIsActive,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        gHost->PropertiesChanged(
            gHost,
            kPeelObjectID_InputStream,
            1u,
            &changedAddress
        );
    }
    return noErr;
}

static OSStatus Peel_StartIO(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID
) {
    if (!Peel_IsDriverReference(inDriver) ||
        inDeviceObjectID != kPeelObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    OSStatus status = noErr;
    pthread_mutex_lock(&gStateMutex);
    if (!gInitialized || !Peel_ClientIsRegisteredLocked(inClientID)) {
        status = kAudioHardwareIllegalOperationError;
    } else if (atomic_load_explicit(
                   &gIOIsRunning,
                   memory_order_acquire
               ) != 0u) {
        status = kAudioHardwareIllegalOperationError;
    } else if (atomic_load_explicit(
                   &gProducerCallsInFlight,
                   memory_order_acquire
               ) != 0u) {
        status = kAudioHardwareIllegalOperationError;
    } else if (atomic_load_explicit(
                   &gConsumerCallInFlight,
                   memory_order_acquire
               ) != 0u) {
        status = kAudioHardwareIllegalOperationError;
    } else if (peel_audio_ring_reset_quiescent(&gAudioRing) !=
               PEEL_AUDIO_RING_OK) {
        status = kAudioHardwareIllegalOperationError;
    } else {
        Peel_BeginTimelineMutationLocked();
        atomic_store_explicit(
            &gIOOwnerClientID,
            inClientID,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &gTimelineAnchorHostTime,
            (unsigned long long)mach_absolute_time(),
            memory_order_relaxed
        );
        atomic_store_explicit(
            &gRenderedFrameCount,
            0u,
            memory_order_relaxed
        );
        (void)Peel_NextNonzeroCounter(&gTimelineSeed);
        const unsigned long long producerGeneration =
            Peel_NextNonzeroCounter(&gProducerGeneration);
        atomic_store_explicit(
            &gIOIsRunning,
            1u,
            memory_order_release
        );
        atomic_store_explicit(
            &gProducerAcceptingFrames,
            producerGeneration == 0u ? 0u : 1u,
            memory_order_release
        );
        Peel_EndTimelineMutationLocked();
    }
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

static OSStatus Peel_StopIO(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID
) {
    if (!Peel_IsDriverReference(inDriver) ||
        inDeviceObjectID != kPeelObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    OSStatus status = noErr;
    pthread_mutex_lock(&gStateMutex);
    if (atomic_load_explicit(&gIOIsRunning, memory_order_acquire) == 0u ||
        atomic_load_explicit(
            &gIOOwnerClientID,
            memory_order_relaxed
        ) != inClientID) {
        status = kAudioHardwareIllegalOperationError;
    } else {
        Peel_EndIOOwnershipLocked();
    }
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

static OSStatus Peel_GetZeroTimeStamp(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID,
    Float64 *outSampleTime,
    UInt64 *outHostTime,
    UInt64 *outSeed
) {
    if (!Peel_IsDriverReference(inDriver) ||
        inDeviceObjectID != kPeelObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    for (unsigned int attempt = 0u; attempt < 3u; ++attempt) {
        const unsigned long long sequenceBefore =
            atomic_load_explicit(
                &gTimelineSequence,
                memory_order_acquire
            );
        if ((sequenceBefore & 1u) != 0u) {
            continue;
        }
        if (atomic_load_explicit(
                &gIOIsRunning,
                memory_order_acquire
            ) == 0u ||
            atomic_load_explicit(
                &gIOOwnerClientID,
                memory_order_relaxed
            ) != inClientID) {
            return kAudioHardwareIllegalOperationError;
        }

        const unsigned long long anchor = atomic_load_explicit(
            &gTimelineAnchorHostTime,
            memory_order_relaxed
        );
        const unsigned long long ticksPerPeriod = atomic_load_explicit(
            &gHostTicksPerZeroTimeStamp,
            memory_order_relaxed
        );
        const unsigned long long seed = atomic_load_explicit(
            &gTimelineSeed,
            memory_order_relaxed
        );
        const unsigned long long now =
            (unsigned long long)mach_absolute_time();
        const unsigned long long elapsed =
            now >= anchor ? now - anchor : 0u;
        const unsigned long long period =
            ticksPerPeriod > 0u ? elapsed / ticksPerPeriod : 0u;
        const unsigned long long sequenceAfter =
            atomic_load_explicit(
                &gTimelineSequence,
                memory_order_acquire
            );

        if (sequenceBefore == sequenceAfter &&
            (sequenceAfter & 1u) == 0u) {
            *outSampleTime =
                (Float64)period *
                (Float64)kPeelZeroTimeStampPeriodFrames;
            *outHostTime =
                (UInt64)(anchor + period * ticksPerPeriod);
            *outSeed = (UInt64)seed;
            return noErr;
        }
    }

    return kAudioHardwareIllegalOperationError;
}

static OSStatus Peel_WillDoIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    Boolean *outWillDo,
    Boolean *outWillDoInPlace
) {
    (void)inClientID;
    if (!Peel_IsDriverReference(inDriver) ||
        inDeviceObjectID != kPeelObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    const Boolean willRead =
        inOperationID == kAudioServerPlugInIOOperationReadInput;
    if (outWillDo != NULL) {
        *outWillDo = willRead;
    }
    if (outWillDoInPlace != NULL) {
        *outWillDoInPlace = true;
    }
    return noErr;
}

static OSStatus Peel_BeginIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo *inIOCycleInfo
) {
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    if (!Peel_IsDriverReference(inDriver) ||
        inDeviceObjectID != kPeelObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return noErr;
}

static OSStatus Peel_DoIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    AudioObjectID inStreamObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
    void *ioMainBuffer,
    void *ioSecondaryBuffer
) {
    (void)inIOCycleInfo;
    (void)ioSecondaryBuffer;
    if (!Peel_IsDriverReference(inDriver) ||
        inDeviceObjectID != kPeelObjectID_Device ||
        inStreamObjectID != kPeelObjectID_InputStream) {
        return kAudioHardwareBadObjectError;
    }
    if (inOperationID != kAudioServerPlugInIOOperationReadInput) {
        return kAudioHardwareUnsupportedOperationError;
    }
    if (inIOBufferFrameSize > 0u && ioMainBuffer == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inIOBufferFrameSize == 0u) {
        return noErr;
    }

    Float32 *output = (Float32 *)ioMainBuffer;
    if (atomic_load_explicit(&gIOIsRunning, memory_order_acquire) == 0u ||
        atomic_load_explicit(
            &gIOOwnerClientID,
            memory_order_relaxed
        ) != inClientID) {
        memset(
            output,
            0,
            (size_t)inIOBufferFrameSize * sizeof(output[0])
        );
        return kAudioHardwareIllegalOperationError;
    }

    unsigned int expectedConsumerCall = 0u;
    if (!atomic_compare_exchange_strong_explicit(
            &gConsumerCallInFlight,
            &expectedConsumerCall,
            1u,
            memory_order_acq_rel,
            memory_order_acquire
        )) {
        memset(
            output,
            0,
            (size_t)inIOBufferFrameSize * sizeof(output[0])
        );
        return kAudioHardwareIllegalOperationError;
    }

    if (atomic_load_explicit(&gIOIsRunning, memory_order_acquire) == 0u ||
        atomic_load_explicit(
            &gIOOwnerClientID,
            memory_order_relaxed
        ) != inClientID) {
        memset(
            output,
            0,
            (size_t)inIOBufferFrameSize * sizeof(output[0])
        );
        atomic_store_explicit(
            &gConsumerCallInFlight,
            0u,
            memory_order_release
        );
        return kAudioHardwareIllegalOperationError;
    }

    PeelAudioRingStatus renderStatus = PEEL_AUDIO_RING_OK;
    uint64_t producerSessionGeneration = 0u;
    if (Peel_PrepareProducerAudioForRead(
            &producerSessionGeneration
        )) {
        const PeelRemoteMicrophoneRenderResult result =
            peel_remote_microphone_render_float32(
                &gAudioRing,
                output,
                (size_t)inIOBufferFrameSize,
                gReadScratch,
                kPeelReadScratchFrames
            );
        renderStatus = result.status;

        /*
         * End/replacement may race this read after the initial generation
         * check. Suppress the already-consumed frames unless the same session
         * is still published and consumer-ready at callback completion.
         */
        if (!peel_producer_lifecycle_session_is_ready(
                &gProducerLifecycle,
                producerSessionGeneration
            )) {
            memset(
                output,
                0,
                (size_t)inIOBufferFrameSize * sizeof(output[0])
            );
        }
    } else {
        memset(
            output,
            0,
            (size_t)inIOBufferFrameSize * sizeof(output[0])
        );
    }

    if (atomic_load_explicit(
            &gInputStreamIsActive,
            memory_order_acquire
        ) == 0u) {
        memset(
            output,
            0,
            (size_t)inIOBufferFrameSize * sizeof(output[0])
        );
    }

    (void)atomic_fetch_add_explicit(
        &gRenderedFrameCount,
        (unsigned long long)inIOBufferFrameSize,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &gConsumerCallInFlight,
        0u,
        memory_order_release
    );

    return renderStatus == PEEL_AUDIO_RING_OK ||
        renderStatus == PEEL_AUDIO_RING_UNDERRUN
        ? noErr
        : kAudioHardwareIllegalOperationError;
}

static OSStatus Peel_EndIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo *inIOCycleInfo
) {
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    if (!Peel_IsDriverReference(inDriver) ||
        inDeviceObjectID != kPeelObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return noErr;
}
