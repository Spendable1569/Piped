<template>
    <div
        ref="container"
        data-shaka-player-container
        class="relative flex max-h-screen w-full justify-center"
        :class="{ 'max-h-[75vh] min-h-64 bg-black': !isEmbed }"
    >
        <video
            ref="videoEl"
            class="w-full"
            data-shaka-player
            :autoplay="shouldAutoPlay"
            :loop="selectedAutoLoop"
            playsinline
            :controls="isHlsActive"
        />
        <button
            v-if="inSegment"
            class="skip-segment-button"
            type="button"
            :aria-label="$t('actions.skip_segment')"
            aria-pressed="false"
            @click="onClickSkipSegment"
        >
            <span v-t="'actions.skip_segment'" />
            <i-fa6-solid-forward-step class="skip-segment-icon" aria-hidden="true" />
        </button>
        <span
            v-if="error > 0"
            v-t="{ path: 'player.failed', args: [error] }"
            class="absolute top-8 rounded-sm bg-black/80 p-2 text-lg backdrop-blur-sm"
        />
        <div
            v-if="showCurrentSpeed"
            class="absolute top-1/2 left-1/2 flex -translate-1/2 transform flex-col items-center gap-6 rounded-4xl bg-white/80 px-8 py-4 text-lg dark:bg-dark-700/80"
        >
            <i-fa6-solid-gauge-high class="size-25 p-5" />
            <span v-text="videoEl.playbackRate" />
        </div>
        <div
            v-if="showCurrentVolume"
            class="absolute top-1/2 left-1/2 flex -translate-1/2 transform flex-col items-center gap-6 rounded-4xl bg-white/80 px-8 py-4 text-lg dark:bg-dark-700/80"
        >
            <i-fa6-solid-volume-high v-if="videoEl.volume > 0" class="size-25 p-5" />
            <i-fa6-solid-volume-xmark v-else class="size-25 p-5" />
            <span v-text="Math.round(videoEl.volume * 100) / 100" />
        </div>
    </div>

    <ModalComponent v-if="showSpeedModal" @close="showSpeedModal = false">
        <h2 v-t="'actions.playback_speed'" />
        <div class="flex flex-col">
            <input
                v-model="playbackSpeedInput"
                class="my-3 h-8 w-auto rounded-md bg-gray-300 px-2.5 text-gray-600 focus:shadow-red-400 focus:outline-2 focus:outline-red-500 dark:bg-dark-400 dark:text-gray-400"
                type="text"
                :placeholder="$t('actions.playback_speed')"
                @keyup.enter="setSpeedFromInput()"
            />
            <button
                v-t="'actions.okay'"
                class="ml-auto inline-block w-min cursor-pointer rounded-sm bg-gray-300 py-2 text-gray-600 hover:bg-gray-500 hover:text-white max-md:px-2 md:px-4 dark:bg-dark-400 dark:text-gray-400 dark:hover:bg-dark-300"
                @click="setSpeedFromInput()"
            />
        </div>
    </ModalComponent>
</template>

<script setup>
import "shaka-player/dist/controls.css";
import { ref, computed, onMounted, onActivated, onDeactivated, onUnmounted } from "vue";
import { useRoute } from "vue-router";
import { useI18n } from "vue-i18n";
import { parseTimeParam } from "@/utils/Misc";
import ModalComponent from "./ModalComponent.vue";
import {
    getPreferenceBoolean,
    getPreferenceNumber,
    getPreferenceString,
    setPreference,
} from "@/composables/usePreferences.js";

const hotkeysImport = import("hotkeys-js");

const route = useRoute();
const { t } = useI18n();

const props = defineProps({
    video: {
        type: Object,
        default: () => {
            return {};
        },
    },
    sponsors: {
        type: Object,
        default: () => {
            return {};
        },
    },
    selectedAutoPlay: Boolean,
    selectedAutoLoop: Boolean,
    isEmbed: Boolean,
});

const emit = defineEmits(["timeupdate", "ended", "navigateNext"]);

const container = ref(null);
const videoEl = ref(null);

const lastUpdate = ref(new Date().getTime());
const initialSeekComplete = ref(false);
const destroying = ref(false);
const inSegment = ref(false);
const showSpeedModal = ref(false);
const showCurrentSpeed = ref(false);
let hideCurrentSpeedTimeout = null;
const showCurrentVolume = ref(false);
let hideCurrentVolumeTimeout = null;
const playbackSpeedInput = ref(null);
const error = ref(0);
const wasDeactivated = ref(false); // New: tracks if component was deactivated

let shakaLib = null;
let playerInstance = null;
let uiInstance = null;
let hotkeysLib = null;
let shakaPromise = null;
let hotkeysPromise = null;
let hlsLib = null;
let hlsInstance = null;
let hlsPromise = null;
let lastSelectedTextTrack = null;
let thumbnailVttUrl = null;
let activePlayer = null; // 'shaka' or 'hls'
const isHlsActive = ref(false);

const shouldAutoPlay = computed(() => {
    return getPreferenceBoolean("playerAutoPlay", true) && !props.isEmbed;
});

const useHlsJs = computed(() => {
    return getPreferenceString("hlsPlayer", "shaka") === "hlsjs";
});

const preferredVideoCodecs = computed(() => {
    var preferredVideoCodecs = [];
    const enabledCodecs = getPreferenceString("enabledCodecs", "vp9,avc").split(",");

    if (videoEl.value.canPlayType('video/mp4; codecs="av01.0.08M.08"') !== "" && enabledCodecs.includes("av1"))
        preferredVideoCodecs.push("av01");
    if (videoEl.value.canPlayType('video/webm; codecs="vp9"') !== "" && enabledCodecs.includes("vp9"))
        preferredVideoCodecs.push("vp9");
    if (videoEl.value.canPlayType('video/mp4; codecs="avc1.4d401f"') !== "" && enabledCodecs.includes("avc"))
        preferredVideoCodecs.push("avc1");

    return preferredVideoCodecs;
});

function findCurrentSegment(time) {
    return props.sponsors?.segments?.find(s => time >= s.segment[0] && time < s.segment[1]);
}

function onClickSkipSegment() {
    skipSegment(videoEl.value);
}

function skipSegment(el, segment) {
    const time = el.currentTime;
    if (!segment) segment = findCurrentSegment(time);
    if (!segment) return;
    console.log("Skipped segment at " + time);
    el.currentTime = segment.segment[1];
    segment.skipped = true;
}

function adjustPlaybackSpeed(newSpeed) {
    const normalizedSpeed = Math.min(4, Math.max(0.25, newSpeed));
    if (activePlayer === "hls") {
        videoEl.value.playbackRate = normalizedSpeed;
    } else if (activePlayer === "shaka" && playerInstance) {
        playerInstance.trickPlay(normalizedSpeed);
    }
    if (hideCurrentSpeedTimeout) window.clearTimeout(hideCurrentSpeedTimeout);
    showCurrentSpeed.value = false;
    showCurrentSpeed.value = true;
    hideCurrentSpeedTimeout = window.setTimeout(() => (showCurrentSpeed.value = false), 1500);
}

function adjustPlaybackVolume(newVolume) {
    const normalizedVolume = Math.min(1, Math.max(0, newVolume));
    videoEl.value.volume = normalizedVolume;
    if (hideCurrentVolumeTimeout) window.clearTimeout(hideCurrentVolumeTimeout);
    showCurrentVolume.value = false;
    showCurrentVolume.value = true;
    hideCurrentVolumeTimeout = window.setTimeout(() => (showCurrentVolume.value = false), 1500);
}

function setSpeedFromInput() {
    try {
        const newSpeed = Number(playbackSpeedInput.value);
        adjustPlaybackSpeed(newSpeed);
    } catch {
        alert(t("actions.invalid_input"));
    }
    showSpeedModal.value = false;
}

function getActiveTextTrack() {
    if (activePlayer === "hls") {
        const tracks = videoEl.value.textTracks;
        for (let i = 0; i < tracks.length; i++) {
            if (tracks[i].mode === "showing") return tracks[i];
        }
        return null;
    } else if (activePlayer === "shaka") {
        return playerInstance?.getTextTracks()?.find(track => track.active) ?? null;
    }
    return null;
}

function selectTextTrack(track) {
    if (activePlayer === "hls") {
        const tracks = videoEl.value.textTracks;
        for (let i = 0; i < tracks.length; i++) {
            tracks[i].mode = track && tracks[i] === track ? "showing" : "hidden";
        }
        if (track) {
            lastSelectedTextTrack = track;
        }
        return;
    } else if (activePlayer === "shaka") {
        playerInstance.selectTextTrack(track ?? null);
        if (track) {
            lastSelectedTextTrack = track;
        }
    }
}

function applyPreferredTextTrack() {
    if (activePlayer === "hls") {
        const textTracks = Array.from(videoEl.value.textTracks);
        const prefSubtitles = getPreferenceString("subtitles", "");
        const autoDisplayCaptions = getPreferenceBoolean("autoDisplayCaptions", false);

        let selectedTrack = null;

        if (prefSubtitles !== "") {
            selectedTrack = textTracks.find(textTrack => textTrack.language == prefSubtitles) ?? null;
        }

        if (!selectedTrack && autoDisplayCaptions) {
            const prefLang = getPreferenceString("hl", "en").substr(0, 2);
            selectedTrack = textTracks.find(textTrack => textTrack.language == prefLang) ?? textTracks[0] ?? null;
        }

        selectTextTrack(selectedTrack);
        return;
    } else if (activePlayer === "shaka") {
        const textTracks = playerInstance.getTextTracks();
        const prefSubtitles = getPreferenceString("subtitles", "");
        const autoDisplayCaptions = getPreferenceBoolean("autoDisplayCaptions", false);

        let selectedTrack = null;

        if (prefSubtitles !== "") {
            selectedTrack = textTracks.find(textTrack => textTrack.language == prefSubtitles) ?? null;
        }

        if (!selectedTrack && autoDisplayCaptions) {
            const prefLang = getPreferenceString("hl", "en").substr(0, 2);
            selectedTrack = textTracks.find(textTrack => textTrack.language == prefLang) ?? textTracks[0] ?? null;
        }

        selectTextTrack(selectedTrack);
    }
}

function updateMarkers() {
    if (activePlayer !== "shaka") return;
    const markers = container.value.querySelector(".shaka-ad-markers");
    const array = ["to right"];
    props.sponsors?.segments?.forEach(segment => {
        const start = (segment.segment[0] / props.video.duration) * 100;
        const end = (segment.segment[1] / props.video.duration) * 100;

        var color = [
            "sponsor",
            "selfpromo",
            "interaction",
            "poi_highlight",
            "intro",
            "outro",
            "preview",
            "filler",
            "music_offtopic",
        ].includes(segment.category)
            ? `var(--spon-seg-${segment.category})`
            : "var(--spon-seg-default)";

        array.push(`transparent ${start}%`);
        array.push(`${color} ${start}%`);
        array.push(`${color} ${end}%`);
        array.push(`transparent ${end}%`);
    });

    if (array.length <= 1) {
        return;
    }

    if (markers) markers.style.background = `linear-gradient(${array.join(",")})`;
}

function updateSponsors() {
    if (getPreferenceBoolean("showMarkers", true) && activePlayer === "shaka") {
        if (shakaLib) updateMarkers();
        else shakaPromise?.then(() => updateMarkers());
    }
}

// Shaka overlays two marker divs inside .shaka-seek-bar-container:
// .shaka-ad-markers (used by updateMarkers) and .shaka-chapter-markers, both
// sized to the 5px container. Paint chapter boundaries on the dedicated
// overlay instead of on .shaka-seek-bar, a 40px-tall <input> whose background
// would render the markers at the input's full touch-target height.
function updateChapterMarkers() {
    if (activePlayer !== "shaka") return;
    const markers = container.value.querySelector(".shaka-chapter-markers");
    if (!markers) return;

    const chapters = props.video.chapters ?? [];
    if (chapters.length === 0) {
        markers.style.background = "transparent";
        return;
    }

    const array = ["to right"];
    for (const chapter of chapters) {
        const start = (chapter.start / props.video.duration) * 100;
        if (start === 0) {
            continue;
        }
        array.push(`transparent ${start}%`);
        array.push(`black ${start}%`);
        array.push(`black calc(${start}% + 1px)`);
        array.push(`transparent calc(${start}% + 1px)`);
    }
    markers.style.background = `linear-gradient(${array.join(",")})`;
}

function getPreviewFramePage() {
    const previewFrames = props.video.previewFrames;
    if (!previewFrames) return null;
    if (Array.isArray(previewFrames)) {
        return previewFrames.findLast(Boolean) ?? previewFrames[previewFrames.length - 1] ?? null;
    }
    return previewFrames;
}

function formatVttTime(milliseconds) {
    const totalSeconds = Math.floor(milliseconds / 1000);
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    const ms = Math.floor(milliseconds % 1000);

    return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(
        2,
        "0",
    )}.${String(ms).padStart(3, "0")}`;
}

function buildThumbnailVtt(framePage) {
    const totalCount =
        framePage.totalCount ?? framePage.urls.length * framePage.framesPerPageX * framePage.framesPerPageY;
    const framesPerPage = framePage.framesPerPageX * framePage.framesPerPageY;

    let vtt = "WEBVTT\n\n";

    for (let frameIndex = 0; frameIndex < totalCount; frameIndex++) {
        const pageIndex = Math.floor(frameIndex / framesPerPage);
        const frameIndexOnPage = frameIndex % framesPerPage;
        const xIndex = frameIndexOnPage % framePage.framesPerPageX;
        const yIndex = Math.floor(frameIndexOnPage / framePage.framesPerPageX);
        const startTime = frameIndex * framePage.durationPerFrame;
        const endTime = Math.min((frameIndex + 1) * framePage.durationPerFrame, props.video.duration * 1000);

        vtt += `${formatVttTime(startTime)} --> ${formatVttTime(endTime)}\n`;
        vtt += `${framePage.urls[pageIndex]}#xywh=${xIndex * framePage.frameWidth},${yIndex * framePage.frameHeight},${
            framePage.frameWidth
        },${framePage.frameHeight}\n\n`;
    }

    return vtt;
}

async function setupThumbnailTrack() {
    if (activePlayer !== "shaka") return;
    const framePage = getPreviewFramePage();
    if (!framePage?.urls?.length) return;

    if (thumbnailVttUrl) {
        URL.revokeObjectURL(thumbnailVttUrl);
        thumbnailVttUrl = null;
    }

    thumbnailVttUrl = URL.createObjectURL(new Blob([buildThumbnailVtt(framePage)], { type: "text/vtt" }));
    await playerInstance.addThumbnailsTrack(thumbnailVttUrl, "text/vtt");
}

async function updateProgressDatabase(time) {
    if (new Date().getTime() - lastUpdate.value < 500) return;
    lastUpdate.value = new Date().getTime();

    if (!initialSeekComplete.value || destroying.value || !props.video.id || !window.db) return;

    var tx = window.db.transaction("watch_history", "readwrite");
    var store = tx.objectStore("watch_history");
    var request = store.get(props.video.id);
    request.onsuccess = function (event) {
        var video = event.target.result;
        if (video) {
            video.currentTime = time;
            store.put(video);
        }
    };
}

function seek(time) {
    if (videoEl.value) {
        videoEl.value.currentTime = time;
    }
}

async function loadShaka(uri, mime) {
    // Destroy any existing HLS instance
    if (hlsInstance) {
        hlsInstance.destroy();
        hlsInstance = null;
    }
    if (activePlayer === "hls") activePlayer = null;

    // Import Shaka if not already loaded
    if (!shakaPromise) {
        shakaPromise = import("shaka-player/dist/shaka-player.ui.js")
            .then(shaka => shaka.default)
            .then(shaka => {
                shakaLib = shaka;
                return shaka;
            });
    }
    const shaka = await shakaPromise;
    shakaLib = shaka;

    const el = videoEl.value;
    // Clean up any previous Shaka UI
    if (uiInstance) {
        uiInstance.destroy();
        uiInstance = null;
        playerInstance = null;
    }

    shaka.polyfill.installAll();
    const localPlayer = new shaka.Player();
    await localPlayer.attach(el);

    const proxyURL = new URL(props.video.proxyUrl);
    let proxyPath = proxyURL.pathname;
    if (proxyPath.lastIndexOf("/") === proxyPath.length - 1) {
        proxyPath = proxyPath.substring(0, proxyPath.length - 1);
    }

    localPlayer.getNetworkingEngine().registerRequestFilter((_type, request) => {
        const uri = request.uris[0];
        var url = new URL(uri);
        const headers = request.headers;
        if (
            url.host.endsWith(".googlevideo.com") ||
            (url.host.endsWith(".lbryplayer.xyz") && (getPreferenceBoolean("proxyLBRY", false) || headers.Range))
        ) {
            url.searchParams.set("host", url.host);
            url.protocol = proxyURL.protocol;
            url.host = proxyURL.host;
            url.pathname = proxyPath + url.pathname;
            request.uris[0] = url.toString();
        }
        if (url.pathname === proxyPath + "/videoplayback") {
            if (headers.Range) {
                url.searchParams.set("range", headers.Range.split("=")[1]);
                request.headers = {};
                request.uris[0] = url.toString();
            }
        }
    });

    localPlayer.configure("streaming.bufferingGoal", Math.max(getPreferenceNumber("bufferGoal", 10), 10));
    localPlayer.configure("streaming.bufferBehind", 300);

    if (!uiInstance) {
        const OpenButton = class extends shaka.ui.Element {
            constructor(parent, controls) {
                super(parent, controls);

                this.newTabButton_ = document.createElement("button");
                this.newTabButton_.classList.add("shaka-cast-button");
                this.newTabButton_.classList.add("shaka-tooltip");
                this.newTabButton_.ariaPressed = "false";

                this.newTabIcon_ = document.createElement("i");
                this.newTabIcon_.classList.add("material-icons-round");
                this.newTabIcon_.textContent = "launch";
                this.newTabButton_.appendChild(this.newTabIcon_);

                const label = document.createElement("label");
                label.classList.add("shaka-overflow-button-label");
                label.classList.add("shaka-overflow-menu-only");
                this.newTabNameSpan_ = document.createElement("span");
                this.newTabNameSpan_.innerText = "Open in new tab";
                label.appendChild(this.newTabNameSpan_);

                this.newTabButton_.appendChild(label);
                this.parent.appendChild(this.newTabButton_);

                this.eventManager.listen(this.newTabButton_, "click", () => {
                    this.video.pause();
                    window.open("/watch?v=" + props.video.id);
                });
            }
        };

        OpenButton.Factory = class {
            create(rootElement, controls) {
                return new OpenButton(rootElement, controls);
            }
        };

        shaka.ui.OverflowMenu.registerElement("open_new_tab", new OpenButton.Factory());

        uiInstance = new shaka.ui.Overlay(localPlayer, container.value, el);

        const overflowMenuButtons = ["quality", "captions", "picture_in_picture", "playback_rate", "remote"];

        if (props.isEmbed) {
            overflowMenuButtons.push("open_new_tab");
        }

        const config = {
            overflowMenuButtons: overflowMenuButtons,
            seekBarColors: {
                base: "var(--player-base)",
                buffered: "var(--player-buffered)",
                played: "var(--player-played)",
            },
        };

        uiInstance.configure(config);
    }

    playerInstance = localPlayer;
    activePlayer = "shaka";
    isHlsActive.value = false;

    const disableVideo = getPreferenceBoolean("listen", false) && !props.video.livestream;
    const prefetchLimit = Math.min(Math.max(getPreferenceNumber("prefetchLimit", 2), 0), 10);

    playerInstance.configure({
        preferredVideoCodecs: preferredVideoCodecs.value,
        preferredAudioCodecs: ["opus", "mp4a"],
        manifest: {
            disableVideo: disableVideo,
        },
        streaming: {
            segmentPrefetchLimit: prefetchLimit,
            retryParameters: {
                maxAttempts: Infinity,
                baseDelay: 250,
                backoffFactor: 1.5,
            },
        },
    });

    const quality = getPreferenceNumber("quality", 0);
    const qualityConds =
        quality > 0 && (props.video.audioStreams.length > 0 || props.video.livestream) && !disableVideo;
    if (qualityConds) playerInstance.configure("abr.enabled", false);

    const time = route.query.t ?? route.query.start;

    var startTime = 0;

    if (time) {
        startTime = parseTimeParam(time);
    } else if (window.db && getPreferenceBoolean("watchHistory", false)) {
        await new Promise(resolve => {
            var tx = window.db.transaction("watch_history", "readonly");
            var store = tx.objectStore("watch_history");
            var request = store.get(props.video.id);
            request.onsuccess = function (event) {
                var video = event.target.result;
                const currentTime = video?.currentTime;
                if (currentTime) {
                    if (currentTime < video.duration * 0.9) {
                        startTime = currentTime;
                    }
                }
                resolve();
            };
        });
    }

    try {
        await playerInstance.load(uri, null, mime);

        if (startTime > 0) {
            el.currentTime = startTime;
            await new Promise(resolve => el.addEventListener("seeked", resolve, { once: true }));
        }
        initialSeekComplete.value = true;

        let lang = "en";
        const prefLang = getPreferenceString("hl", "en").substr(0, 2);
        const audioTracks = playerInstance.getAudioTracks();
        const audioLanguages = [...new Set(audioTracks.map(t => t.language))];
        if (audioLanguages.includes(prefLang)) lang = prefLang;
        const selectedTrack = audioTracks.find(t => t.language === lang);
        if (selectedTrack) playerInstance.selectAudioTrack(selectedTrack);

        if (audioLanguages.length > 1) {
            const overflowMenuButtons = uiInstance.getConfiguration().overflowMenuButtons;
            const newOverflowMenuButtons = [
                ...overflowMenuButtons.slice(0, 1),
                "language",
                ...overflowMenuButtons.slice(1),
            ];
            uiInstance.configure("overflowMenuButtons", newOverflowMenuButtons);
        }

        if (qualityConds) {
            var leastDiff = Number.MAX_VALUE;
            var bestStream = null;
            var bestAudio = 0;

            const tracks = playerInstance
                .getVariantTracks()
                .filter(track => track.language == lang || track.language == "und");

            if (quality >= 480)
                tracks.forEach(track => {
                    const audioBandwidth = track.audioBandwidth;
                    if (audioBandwidth > bestAudio) bestAudio = audioBandwidth;
                });

            tracks
                .sort((a, b) => a.bandwidth - b.bandwidth)
                .forEach(stream => {
                    if (stream.audioBandwidth < bestAudio) return;

                    const diff = Math.abs(quality - stream.height);
                    if (diff < leastDiff) {
                        leastDiff = diff;
                        bestStream = stream;
                    }
                });

            playerInstance.selectVariantTrack(bestStream, true);
        }

        await Promise.all(
            props.video.subtitles.map(subtitle => {
                return playerInstance.addTextTrackAsync(
                    subtitle.url,
                    subtitle.code,
                    "subtitles",
                    subtitle.mimeType,
                    null,
                    subtitle.name,
                );
            }),
        );
        el.volume = getPreferenceNumber("volume", 1);
        const rate = getPreferenceNumber("rate", 1);
        el.playbackRate = rate;
        el.defaultPlaybackRate = rate;

        applyPreferredTextTrack();
        await setupThumbnailTrack();
    } catch (e) {
        console.error(e);
        error.value = e.code;
    }

    if (route.query.fullscreen === "true" && !uiInstance.getControls().isFullScreenEnabled())
        uiInstance.getControls().toggleFullScreen();

    updateChapterMarkers();

    const seekbar = container.value.querySelector(".shaka-seek-bar");
    if (seekbar) {
        seekbar.addEventListener("mouseup", () => {
            videoEl.value.focus();
        });
    }
}

async function loadHls(uri) {
    // Destroy any existing Shaka instance
    if (uiInstance) {
        uiInstance.destroy();
        uiInstance = null;
        playerInstance = null;
    }
    if (playerInstance) {
        playerInstance.destroy();
        playerInstance = null;
    }
    if (activePlayer === "shaka") activePlayer = null;

    // Import Hls.js if not already loaded
    if (!hlsPromise) {
        hlsPromise = import("hls.js")
            .then(mod => mod.default)
            .then(hls => {
                hlsLib = hls;
                return hls;
            });
    }
    hlsLib = await hlsPromise;

    const el = videoEl.value;
    // Clean up existing HLS instance
    if (hlsInstance) {
        hlsInstance.destroy();
        hlsInstance = null;
    }

    // Remove any existing subtitle tracks
    while (el.firstChild) {
        el.removeChild(el.firstChild);
    }

    el.setAttribute("poster", props.video.thumbnailUrl);

    hlsInstance = new hlsLib({});
    hlsInstance.attachMedia(el);

    hlsInstance.on(hlsLib.Events.MEDIA_ATTACHED, () => {
        hlsInstance.loadSource(uri);
    });

    hlsInstance.on(hlsLib.Events.MANIFEST_PARSED, async () => {
        const time = route.query.t ?? route.query.start;
        let startTime = 0;

        if (time) {
            startTime = parseTimeParam(time);
        } else if (window.db && getPreferenceBoolean("watchHistory", false)) {
            await new Promise(resolve => {
                var tx = window.db.transaction("watch_history", "readonly");
                var store = tx.objectStore("watch_history");
                var request = store.get(props.video.id);
                request.onsuccess = function (event) {
                    var video = event.target.result;
                    const currentTime = video?.currentTime;
                    if (currentTime) {
                        if (currentTime < video.duration * 0.9) {
                            startTime = currentTime;
                        }
                    }
                    resolve();
                };
            });
        }

        if (startTime > 0) {
            el.currentTime = startTime;
            await new Promise(resolve => el.addEventListener("seeked", resolve, { once: true }));
        }
        initialSeekComplete.value = true;

        el.volume = getPreferenceNumber("volume", 1);
        const rate = getPreferenceNumber("rate", 1);
        el.playbackRate = rate;
        el.defaultPlaybackRate = rate;

        // Filter levels by preferred video codecs
        // Map preferred codec families to the prefixes used in HLS manifests
        const codecPrefixMap = {
            vp9: "vp09",
            avc1: "avc1",
            av01: "av01",
        };
        const allowedPrefixes = preferredVideoCodecs.value.map(codec => codecPrefixMap[codec] || codec);

        if (allowedPrefixes.length > 0) {
            // Iterate backwards to safely remove levels
            for (let i = hlsInstance.levels.length - 1; i >= 0; i--) {
                const level = hlsInstance.levels[i];
                const videoCodec = level.videoCodec || "";
                const isAllowed = allowedPrefixes.some(prefix => videoCodec.startsWith(prefix));
                if (!isAllowed) {
                    hlsInstance.removeLevel(i);
                }
            }
        }

        // ------------------------------
        // Filter levels by resolution, frame rate, and HDR (PQ)
        // ------------------------------
        function getVideoRange(level) {
            if (level.attrs && level.attrs["VIDEO-RANGE"]) return level.attrs["VIDEO-RANGE"];
            if (level._attrs && level._attrs.length > 0 && level._attrs[0]["VIDEO-RANGE"])
                return level._attrs[0]["VIDEO-RANGE"];
            return null;
        }

        function filterHlsLevelsByResolutionAndFrameRate() {
            const levels = hlsInstance.levels;
            if (!levels || levels.length === 0) return;

            // Group indices by resolution
            const resMap = new Map(); // key: "WxH", value: array of indices
            for (let i = 0; i < levels.length; i++) {
                const level = levels[i];
                if (level.width && level.height) {
                    const key = `${level.width}x${level.height}`;
                    if (!resMap.has(key)) resMap.set(key, []);
                    resMap.get(key).push(i);
                }
            }

            const indicesToRemove = new Set();

            // Step 1: keep only highest frame rate per resolution
            for (const [, indices] of resMap.entries()) {
                if (indices.length <= 1) continue;
                let maxFrameRate = 0;
                for (const idx of indices) {
                    const fr = levels[idx].frameRate || 0;
                    if (fr > maxFrameRate) maxFrameRate = fr;
                }
                if (maxFrameRate === 0) continue; // cannot determine, skip
                for (const idx of indices) {
                    const fr = levels[idx].frameRate || 0;
                    if (fr < maxFrameRate) indicesToRemove.add(idx);
                }
            }

            if (indicesToRemove.size > 0) {
                const sorted = Array.from(indicesToRemove).sort((a, b) => b - a);
                for (const idx of sorted) hlsInstance.removeLevel(idx);
            }

            // Re‑group remaining levels for HDR check
            const newLevels = hlsInstance.levels;
            const resMap2 = new Map();
            for (let i = 0; i < newLevels.length; i++) {
                const level = newLevels[i];
                if (level.width && level.height) {
                    const key = `${level.width}x${level.height}`;
                    if (!resMap2.has(key)) resMap2.set(key, []);
                    resMap2.get(key).push(i);
                }
            }

            // Step 2: if still multiple per resolution, prefer HDR (PQ)
            const indicesToRemove2 = new Set();
            for (const [, indices] of resMap2.entries()) {
                if (indices.length <= 1) continue;
                const hasHDR = indices.some(idx => getVideoRange(newLevels[idx]) === "PQ");
                if (hasHDR) {
                    for (const idx of indices) {
                        if (getVideoRange(newLevels[idx]) !== "PQ") indicesToRemove2.add(idx);
                    }
                }
            }

            if (indicesToRemove2.size > 0) {
                const sorted2 = Array.from(indicesToRemove2).sort((a, b) => b - a);
                for (const idx of sorted2) hlsInstance.removeLevel(idx);
            }

            // Step 3: if still multiple per resolution, keep only levels with audio group "234" (if any exist)
            const levelsAfterStep2 = hlsInstance.levels;
            const resMap3 = new Map();
            for (let i = 0; i < levelsAfterStep2.length; i++) {
                const level = levelsAfterStep2[i];
                if (level.width && level.height) {
                    const key = `${level.width}x${level.height}`;
                    if (!resMap3.has(key)) resMap3.set(key, []);
                    resMap3.get(key).push(i);
                }
            }

            const indicesToRemove3 = new Set();
            for (const [, indices] of resMap3.entries()) {
                if (indices.length <= 1) continue;
                const hasAudio234 = indices.some(idx => {
                    const level = levelsAfterStep2[idx];
                    return level._audioGroups && level._audioGroups.includes("234");
                });
                if (hasAudio234) {
                    for (const idx of indices) {
                        const level = levelsAfterStep2[idx];
                        if (!(level._audioGroups && level._audioGroups.includes("234"))) {
                            indicesToRemove3.add(idx);
                        }
                    }
                }
            }

            if (indicesToRemove3.size > 0) {
                const sorted3 = Array.from(indicesToRemove3).sort((a, b) => b - a);
                for (const idx of sorted3) hlsInstance.removeLevel(idx);
            }
        }

        filterHlsLevelsByResolutionAndFrameRate();

        const quality = getPreferenceNumber("quality", 0);
        if (quality > 0 && hlsInstance.levels.length > 0) {
            let bestLevelIndex = -1;
            let leastDiff = Number.MAX_VALUE;

            hlsInstance.levels.forEach((level, index) => {
                if (!level.height) return; // skip audio-only or undefined heights
                const diff = Math.abs(quality - level.height);
                if (diff < leastDiff) {
                    leastDiff = diff;
                    bestLevelIndex = index;
                }
            });

            if (bestLevelIndex !== -1) {
                // Setting currentLevel to a specific index automatically disables auto level switching
                hlsInstance.currentLevel = bestLevelIndex;
            }
        }

        // Select audio track based on UI language preference
        const prefLang = getPreferenceString("hl", "en").substr(0, 2);
        const audioTracks = hlsInstance.audioTracks || [];
        if (audioTracks.length > 0) {
            // Try to find a track matching the preferred language
            let selectedTrack = audioTracks.find(track => track.lang === prefLang);
            if (!selectedTrack) {
                selectedTrack = audioTracks.find(track => track.lang.startsWith(prefLang));
            }
            // Fallback to English
            if (!selectedTrack) {
                selectedTrack = audioTracks.find(track => track.lang === "en");
            }
            if (!selectedTrack) {
                selectedTrack = audioTracks.find(track => track.lang.startsWith("en"));
            }
            // Fallback to the first available track
            if (!selectedTrack) {
                selectedTrack = audioTracks[0];
            }
            // Apply the selection
            if (selectedTrack) {
                hlsInstance.audioTrack = selectedTrack.id;
            }
        }

        props.video.subtitles.forEach(subtitle => {
            const track = document.createElement("track");
            track.kind = "subtitles";
            track.label = subtitle.name;
            track.srclang = subtitle.code;
            track.src = subtitle.url;
            el.appendChild(track);
        });

        el.addEventListener(
            "loadedmetadata",
            () => {
                applyPreferredTextTrack();
            },
            { once: true },
        );
    });

    hlsInstance.on(hlsLib.Events.ERROR, (event, data) => {
        if (data.fatal) {
            console.error("HLS.js fatal error:", data);
            error.value = data.type;
            hlsInstance.destroy();
        }
    });

    activePlayer = "hls";
    isHlsActive.value = true;
}

async function loadVideo() {
    initialSeekComplete.value = false;

    updateSponsors();

    const el = videoEl.value;

    el.setAttribute("poster", props.video.thumbnailUrl);

    let shouldUseHls = false;
    if (useHlsJs.value) {
        if (props.video.livestream) {
            // Livestreams rely on HLS; use hls.js if selected
            shouldUseHls = true;
        } else {
            const preferHls = getPreferenceBoolean("preferHls", false);
            if (preferHls) {
                // Prefer HLS: use hls.js whenever an HLS source exists
                shouldUseHls = !!props.video.hls;
            } else {
                // Use hls.js only if HLS is the sole available source
                const hasDash = !!props.video.dash;
                const hasOtherStreams =
                    (props.video.audioStreams && props.video.audioStreams.length > 0) ||
                    (props.video.videoStreams && props.video.videoStreams.length > 0);
                shouldUseHls = !!props.video.hls && !hasDash && !hasOtherStreams;
            }
        }
    }

    if (shouldUseHls) {
        const hlsUrl = props.video.hls;
        if (!hlsUrl) {
            console.error("HLS source not found");
            return;
        }
        await loadHls(hlsUrl);
        return;
    }

    const noPrevPlayer = !playerInstance;

    var streams = [];

    streams.push(...props.video.audioStreams);
    streams.push(...props.video.videoStreams);

    const MseSupport = window.MediaSource !== undefined || window.ManagedMediaSource !== undefined;

    const lbry = null;

    var uri;
    var mime;

    if (props.video.livestream) {
        uri = props.video.hls;
        mime = "application/x-mpegURL";
    } else if (
        props.video.audioStreams.length > 0 &&
        !lbry &&
        MseSupport &&
        !getPreferenceBoolean("preferHls", false)
    ) {
        if (!props.video.dash) {
            const dash = (await import("../utils/DashUtils.js")).generate_dash_file_from_formats(
                streams,
                props.video.duration,
            );

            uri = "data:application/dash+xml;charset=utf-8;base64," + btoa(dash);
        } else {
            const url = new URL(props.video.dash);
            url.searchParams.set("rewrite", false);
            uri = url.toString();
        }
        mime = "application/dash+xml";
    } else if (lbry) {
        uri = lbry.url;
        if (getPreferenceBoolean("proxyLBRY", false)) {
            const url = new URL(uri);
            const proxyURL = new URL(props.video.proxyUrl);
            let proxyPath = proxyURL.pathname;
            if (proxyPath.lastIndexOf("/") === proxyPath.length - 1) {
                proxyPath = proxyPath.substring(0, proxyPath.length - 1);
            }

            url.searchParams.set("host", url.host);
            url.protocol = proxyURL.protocol;
            url.host = proxyURL.host;
            url.pathname = proxyPath + url.pathname;
            uri = url.toString();
        }
        const contentType = await fetch(uri, {
            method: "HEAD",
        }).then(response => {
            uri = response.url;
            return response.headers.get("Content-Type");
        });
        mime = contentType;
    } else if (props.video.dash && !getPreferenceBoolean("preferHls", false)) {
        uri = props.video.dash;
        mime = "application/dash+xml";
    } else if (props.video.hls) {
        uri = props.video.hls;
        mime = "application/x-mpegURL";
    } else {
        uri = props.video.videoStreams.findLast(stream => stream.codec == null).url;
        mime = "video/mp4";
    }

    await loadShaka(uri, mime);

    if (noPrevPlayer) {
        el.addEventListener("loadeddata", () => {
            if (document.pictureInPictureElement) el.requestPictureInPicture();
        });
        el.addEventListener("timeupdate", () => {
            const time = el.currentTime;
            emit("timeupdate", time);
            updateProgressDatabase(time);
            if (props.sponsors && props.sponsors.segments) {
                const segment = findCurrentSegment(time);
                inSegment.value = !!segment;
                if (segment?.autoskip && (!segment.skipped || props.selectedAutoLoop)) {
                    skipSegment(el, segment);
                }
            }
        });

        el.addEventListener("volumechange", () => {
            setPreference("volume", el.volume, true);
        });

        el.addEventListener("ratechange", e => {
            const rate = el.playbackRate;
            if (rate > 0 && !isNaN(el.duration) && !isNaN(el.duration - e.timeStamp / 1000))
                setPreference("rate", rate, true);
        });

        el.addEventListener("ended", () => {
            emit("ended");
        });
    }
}

function destroy(hotkeys) {
    if (thumbnailVttUrl) {
        URL.revokeObjectURL(thumbnailVttUrl);
        thumbnailVttUrl = null;
    }
    if (hlsInstance) {
        hlsInstance.destroy();
        hlsInstance = null;
    }
    if (uiInstance && !document.pictureInPictureElement) {
        uiInstance.destroy();
        uiInstance = undefined;
        playerInstance = undefined;
    }
    if (playerInstance) {
        playerInstance.destroy();
        if (!document.pictureInPictureElement) playerInstance = undefined;
    }
    if (hotkeys) hotkeysLib?.unbind();
    container.value?.querySelectorAll("div").forEach(node => node.remove());
    activePlayer = null;
}

onMounted(() => {
    if (!hotkeysLib) hotkeysPromise = hotkeysImport.then(mod => mod.default).then(hk => (hotkeysLib = hk));
});

onActivated(() => {
    destroying.value = false;
    props.sponsors?.segments?.forEach(segment => (segment.skipped = false));
    hotkeysPromise.then(() => {
        hotkeysLib(
            "f,m,j,k,l,c,space,up,down,left,right,ctrl+left,ctrl+right,home,end,0,1,2,3,4,5,6,7,8,9,shift+n,shift+s,shift+,,shift+.,alt+p,return,.,,",
            function (e, handler) {
                const el = videoEl.value;
                switch (handler.key) {
                    case "f":
                        if (activePlayer === "hls") {
                            if (document.fullscreenElement) {
                                document.exitFullscreen();
                            } else {
                                el.parentElement.requestFullscreen();
                            }
                        } else if (activePlayer === "shaka" && uiInstance) {
                            uiInstance.getControls().toggleFullScreen();
                        }
                        e.preventDefault();
                        break;
                    case "m":
                        el.muted = !el.muted;
                        e.preventDefault();
                        break;
                    case "j":
                        el.currentTime = Math.max(el.currentTime - 15, 0);
                        e.preventDefault();
                        break;
                    case "l":
                        el.currentTime = el.currentTime + 15;
                        e.preventDefault();
                        break;
                    case "c":
                        if (getActiveTextTrack()) {
                            lastSelectedTextTrack = getActiveTextTrack();
                            selectTextTrack(null);
                        } else if (lastSelectedTextTrack) {
                            selectTextTrack(lastSelectedTextTrack);
                        } else {
                            const tracks =
                                activePlayer === "hls"
                                    ? Array.from(el.textTracks)
                                    : (playerInstance?.getTextTracks() ?? []);
                            selectTextTrack(tracks[0] ?? null);
                        }
                        e.preventDefault();
                        break;
                    case "k":
                    case "space":
                        if (el.paused) el.play();
                        else el.pause();
                        e.preventDefault();
                        break;
                    case "up":
                        adjustPlaybackVolume(el.volume + 0.05);
                        e.preventDefault();
                        break;
                    case "down":
                        adjustPlaybackVolume(el.volume - 0.05);
                        e.preventDefault();
                        break;
                    case "left":
                        el.currentTime = Math.max(el.currentTime - 5, 0);
                        e.preventDefault();
                        break;
                    case "right":
                        el.currentTime = el.currentTime + 5;
                        e.preventDefault();
                        break;
                    case "ctrl+left": {
                        el.currentTime = props.video.chapters.findLast(chapter => chapter.start < el.currentTime).start;
                        e.preventDefault();
                        break;
                    }
                    case "ctrl+right": {
                        el.currentTime =
                            props.video.chapters.find(chapter => chapter.start > el.currentTime)?.start || el.duration;
                        e.preventDefault();
                        break;
                    }
                    case "home":
                        el.currentTime = 0;
                        e.preventDefault();
                        break;
                    case "end":
                        el.currentTime = el.duration;
                        e.preventDefault();
                        break;
                    case "0":
                        el.currentTime = 0;
                        e.preventDefault();
                        break;
                    case "1":
                        el.currentTime = el.duration * 0.1;
                        e.preventDefault();
                        break;
                    case "2":
                        el.currentTime = el.duration * 0.2;
                        e.preventDefault();
                        break;
                    case "3":
                        el.currentTime = el.duration * 0.3;
                        e.preventDefault();
                        break;
                    case "4":
                        el.currentTime = el.duration * 0.4;
                        e.preventDefault();
                        break;
                    case "5":
                        el.currentTime = el.duration * 0.5;
                        e.preventDefault();
                        break;
                    case "6":
                        el.currentTime = el.duration * 0.6;
                        e.preventDefault();
                        break;
                    case "7":
                        el.currentTime = el.duration * 0.7;
                        e.preventDefault();
                        break;
                    case "8":
                        el.currentTime = el.duration * 0.8;
                        e.preventDefault();
                        break;
                    case "9":
                        el.currentTime = el.duration * 0.9;
                        e.preventDefault();
                        break;
                    case "shift+n":
                        emit("navigateNext");
                        e.preventDefault();
                        break;
                    case "shift+s":
                        showSpeedModal.value = true;
                        break;
                    case "shift+,":
                        adjustPlaybackSpeed(el.playbackRate - 0.25);
                        break;
                    case "shift+.":
                        adjustPlaybackSpeed(el.playbackRate + 0.25);
                        break;
                    case "alt+p":
                        document.pictureInPictureElement
                            ? document.exitPictureInPicture()
                            : el.requestPictureInPicture();
                        break;
                    case "return":
                        skipSegment(el);
                        break;
                    case ".":
                        el.currentTime += 0.04;
                        e.preventDefault();
                        break;
                    case ",":
                        el.currentTime -= 0.04;
                        e.preventDefault();
                        break;
                }
            },
        );
    });

    // Re‑initialize player if the component was previously deactivated
    if (wasDeactivated.value) {
        wasDeactivated.value = false;
        loadVideo();
    }
});

onDeactivated(() => {
    destroying.value = true;
    wasDeactivated.value = true;
    destroy(true);
});

onUnmounted(() => {
    destroying.value = true;
    destroy(true);
});

defineExpose({
    loadVideo,
    seek,
    destroy,
    updateSponsors,
    isFullScreenEnabled: () => {
        if (activePlayer === "hls") {
            return document.fullscreenElement != null;
        }
        if (activePlayer === "shaka" && uiInstance) {
            return uiInstance.getControls().isFullScreenEnabled();
        }
        return false;
    },
});
</script>

<style>
@layer base {
    :root {
        --player-base: rgba(255, 255, 255, 0.3);
        --player-buffered: rgba(255, 255, 255, 0.54);
        --player-played: rgba(255, 0, 0);

        --spon-seg-sponsor: #00d400;
        --spon-seg-selfpromo: #ffff00;
        --spon-seg-interaction: #cc00ff;
        --spon-seg-poi_highlight: #ff1684;
        --spon-seg-intro: #00ffff;
        --spon-seg-outro: #0202ed;
        --spon-seg-preview: #008fd6;
        --spon-seg-filler: #7300ff;
        --spon-seg-music_offtopic: #ff9900;
        --spon-seg-default: white;
    }
}

@layer components {
    .shaka-video-container .material-icons-round {
        font-size: 1.25rem !important;
        line-height: 1.75rem;
    }

    .shaka-video-container:-webkit-full-screen {
        max-height: none !important;
    }

    /* captions style */
    .shaka-text-wrapper * {
        text-align: left !important;
    }

    .shaka-text-wrapper > span > span {
        background-color: transparent !important;
    }

    /* apply to all spans that don't include multiple other spans to avoid the style being applied to the text container too when the subtitles are two lines */
    .shaka-text-wrapper > span > span *:first-child:last-child {
        background-color: rgba(0, 0, 0, 0.6) !important;
        padding: 0.09em 0;
    }

    /* Override Tailwind preflight's `img { max-width: 100% }` which clamps
       the sprite-sheet image to the container width and breaks Shaka's
       transform-based thumbnail cropping. */
    .shaka-player-ui-thumbnail-image {
        max-width: none !important;
    }
}

/* Suppress Firefox/Gecko's blue :focus outline on the <video> element.
   We explicitly .focus() the video on seek-bar mouseup (so hotkeys-js keeps
   receiving keys), and Gecko draws a system focus outline whenever a <video>
   is focused. Chromium uses :focus-visible heuristics on media elements so it
   doesn't render the outline for click-driven focus. Kept outside @layer so
   it wins over any layered rule, and !important to override the UA focus ring
   if specificity gets shadowed. */
video.shaka-video:focus,
video[data-shaka-player]:focus {
    outline: none !important;
}
</style>
