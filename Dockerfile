FROM --platform=$TARGETPLATFORM docker.io/library/node:24-alpine as deemix

ARG TARGETPLATFORM
ARG BUILDPLATFORM

RUN echo "Building for TARGETPLATFORM=$TARGETPLATFORM | BUILDPLATFORM=$BUILDPLATFORM"
RUN apk add --no-cache git jq python3 make gcc musl-dev g++ && \
    rm -rf /var/lib/apt/lists/*
RUN git clone --recurse-submodules https://gitlab.com/RemixDev/deemix-gui.git
WORKDIR deemix-gui
RUN case "$TARGETPLATFORM" in \
        "linux/amd64") \
            jq '.pkg.targets = ["node24-alpine-x64"]' ./server/package.json > tmp-json ;; \
        "linux/arm64") \
            jq '.pkg.targets = ["node24-alpine-arm64"]' ./server/package.json > tmp-json ;; \
        *) \
            echo "Platform $TARGETPLATFORM not supported" && exit 1 ;; \
    esac && \
    mv tmp-json /deemix-gui/server/package.json
# vercel/pkg is archived and only supports Node.js through 18. Use its maintained
# fork so the packaged server embeds the current Node 24 runtime.
RUN jq 'del(.devDependencies.pkg) | .devDependencies["@yao-pkg/pkg"] = "6.25.0"' package.json > tmp-json && \
    mv tmp-json package.json
RUN yarn install-all
# Deezer can omit MEDIA or EXPLICIT_TRACK_CONTENT for unavailable tracks. Guard
# those fields so one incomplete track does not abort the whole download.
RUN find . -type f \( -name '*.js' -o -name '*.ts' \) -not -path '*/.git/*' -exec sed -i \
        -e 's/track\.EXPLICIT_TRACK_CONTENT\.EXPLICIT_LYRICS_STATUS/track.EXPLICIT_TRACK_CONTENT?.EXPLICIT_LYRICS_STATUS/g' \
        -e 's/track\.EXPLICIT_TRACK_CONTENT\.EXPLICIT_COVER_STATUS/track.EXPLICIT_TRACK_CONTENT?.EXPLICIT_COVER_STATUS/g' \
        -e 's/track\.MEDIA\[0\]\.HREF/track.MEDIA?.[0]?.HREF/g' \
        -e 's/track\.MEDIA\[0\]?\.HREF/track.MEDIA?.[0]?.HREF/g' {} +
# Patching deemix: see issue https://github.com/youegraillot/lidarr-on-steroids/issues/63
RUN sed -i 's/const channelData = await dz.gw.get_page(channelName)/let channelData; try { channelData = await dz.gw.get_page(channelName); } catch (error) { console.error(`Caught error ${error}`); return [];}/' ./server/src/routes/api/get/newReleases.ts
RUN sed -i '/output.DURATION = duration/i\	if (duration === 0) duration = Number(result.SONGS.total) * 180' ./server/src/routes/api/get/albumSearch.ts
RUN yarn dist-server
RUN mv /deemix-gui/dist/deemix-server /deemix-server


FROM ghcr.io/hotio/lidarr:pr-plugins-3.1.2.4913

LABEL maintainer="youegraillot"

ENV DEEMIX_SINGLE_USER=true
ENV AUTOCONFIG=true
ENV CLEAN_DOWNLOADS=true
ENV PUID=1000
ENV PGID=1000

# flac2mp3
RUN apk add --no-cache ffmpeg && \
    rm -rf /var/lib/apt/lists/*
COPY lidarr-flac2mp3/root/usr /usr

# deemix
COPY --from=deemix /deemix-server /deemix-server
RUN chmod +x /deemix-server
VOLUME ["/config_deemix", "/downloads"]
EXPOSE 6595

# arl-watch
RUN apk add --no-cache inotify-tools && \
    rm -rf /var/lib/apt/lists/*

COPY root /
RUN chmod +x /etc/services.d/*/run && \
    chmod +x /usr/local/bin/*.sh

VOLUME ["/config", "/music"]
EXPOSE 6595 8686
