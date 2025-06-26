FROM debian:bullseye

RUN apt-get update && \
    apt-get install -y build-essential stress-ng && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["stress-ng"]