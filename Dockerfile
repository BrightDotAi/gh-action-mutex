FROM public.ecr.aws/docker/library/alpine:3.19

RUN  apk update \
  && apk add --no-cache bash curl git

COPY rootfs/ /
