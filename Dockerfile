FROM dart:stable AS build
WORKDIR /src
COPY pubspec.yaml ./
RUN dart pub get
COPY bin ./bin
RUN dart compile exe bin/relay.dart -o /private-folder-relay

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /private-folder-relay /private-folder-relay
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/private-folder-relay"]

