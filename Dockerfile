# syntax=docker/dockerfile:1

## Redash
# This build file has four stages as outlined below:
#
# 1. frontend-builder, used to build the node front-end
# 2. ubi, a base image sitting on top of rhel9
# 3. debian, a base image sitting on top of debian bullseye
# 4. redash, the python application (with the front-end copied to it)
#
# The first image -- the `frontend-builder` -- is not distributed as part of the application. It's simply there to allow
# for caching and to avoid unnecessarily inflating the final image with all the node application's dependencies.
# The next two images -- the `ubi` and `debian` images -- are the base operating system images. Any dependencies that
# the redash application requires must be installed in these layers. By using the `base` build-arg (described below)
# we can switch out the underlying operating system at build time.
# The final image -- `redash` -- contains the python application. This image is the one that's distributed on
# hub.docker.com

# Controls the base operating system, either ubi (and thus registry.access.redhat.com/ubi9) as the base,
# or debian (and thus python:3.8.14-slim-bullseye).
# Set on the command line via `docker build --build-arg base=debian`
ARG base=ubi

FROM node:14.17-bullseye as frontend-builder

# Controls whether to build the frontend assets
ARG skip_frontend_build

ENV CYPRESS_INSTALL_BINARY=0
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1

RUN useradd -m -d /frontend redash
USER redash

WORKDIR /frontend
COPY --chown=redash package.json package-lock.json /frontend/
COPY --chown=redash viz-lib /frontend/viz-lib

# Controls whether to instrument code for coverage information
ARG code_coverage
ENV BABEL_ENV=${code_coverage:+test}

RUN if [ "x$skip_frontend_build" = "x" ] ; then npm ci --unsafe-perm; fi

COPY --chown=redash client /frontend/client
COPY --chown=redash webpack.config.js /frontend/
RUN if [ "x$skip_frontend_build" = "x" ] ; then npm run build; else mkdir -p /frontend/client/dist && touch /frontend/client/dist/multi_org.html && touch /frontend/client/dist/index.html; fi

FROM --platform=amd64 registry.access.redhat.com/ubi9/python-39 as ubi
USER root
RUN yum install --assumeyes \
      postgresql

# This variable is part of the base UBI image
USER $CNB_USER_ID

FROM --platform=amd64 python:3.8.14-slim-bullseye as debian

USER root
RUN apt-get update &&\
  apt-get upgrade -y && \
  apt-get autoremove -y && \
  apt-get install -y \
    curl \
    gnupg \
    build-essential \
    pwgen \
    libffi-dev \
    sudo \
    git-core \
    wget \
    # Postgres client
    libpq-dev \
    # Additional packages required for data sources:
    libssl-dev \
    freetds-dev \
    libsasl2-dev \
    unzip \
    libsasl2-modules-gssapi-mit

RUN useradd --create-home redash
USER redash

FROM $base as redash

EXPOSE 5000
# Controls whether to install extra dependencies needed for all data sources.
ARG skip_ds_deps
# Controls whether to install dev dependencies.
ARG skip_dev_deps

WORKDIR /app

# Disable pip cache and version check
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PIP_NO_CACHE_DIR=1

# rollback pip version to avoid legacy resolver problem
RUN pip install pip==21.1;

# We first copy only the requirements file, to avoid rebuilding on every file change.
COPY requirements_all_ds.txt ./
RUN if [ "x$skip_ds_deps" = "x" ] ; then pip install -r requirements_all_ds.txt ; else echo "Skipping pip install -r requirements_all_ds.txt" ; fi

COPY requirements_bundles.txt requirements_dev.txt ./
RUN if [ "x$skip_dev_deps" = "x" ] ; then pip install -r requirements_dev.txt ; fi

COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY . /app
COPY --from=frontend-builder /frontend/client/dist /app/client/dist

ENV SUMMARY="Redash - data visualisation" \
    DESCRIPTION="Redash is a data visualisation web application, connect data \
        sources and embed visualisations in dashboards." \
    MAINTAINER="Diffblue <support@diffblue.com>"

LABEL summary="$SUMMARY" \
      description="$DESCRIPTION" \
      io.k8s.description="$DESCRIPTION" \
      io.k8s.display-name="Redash" \
      io.openshift.expose-services="5000:http" \
      io.openshift.tags="redash" \
      name="diffblue/redash" \
      version="1" \
      usage="" \
      io.buildpacks.stack.id="com.diffblue.cover-reports.redash" \
      maintainer="$MAINTAINER" \
      org.opencontainers.image.authors="$MAINTAINER"

# There are three paths we need to prepend to the PATH.
# `/opt/app-root/bin` and `/opt/app-root/src/.local/bin/` are for redhat/ubi, while `/home/redash/.local/bin/` is for
# debian. These are needed to point to `gunicorn` (which runs the server for the flask app and thus redash). With out
# these there is no server and the container will not start. Ideally, they'd be specified in each of the containers
# and we'd not cross polinate, however, when we create the underlying images we've not yet installed pip, let alone
# gunicorn.
ENV PATH=/home/redash/.local/bin/:/opt/app-root/bin:/opt/app-root/src/.local/bin/:${PATH}
ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["server"]
