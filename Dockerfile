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

FROM --platform=amd64 registry.access.redhat.com/ubi9/python-39
USER root
RUN yum install --assumeyes \
      postgresql

# This variable is part of the base UBI image
USER $CNB_USER_ID


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

ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["server"]
