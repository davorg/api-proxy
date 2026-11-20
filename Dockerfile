FROM perl:5.42

WORKDIR /app

# Install from the same dependency list used by local development. Copy both
# cpanfiles before source code so application changes can reuse this layer.
COPY cpanfile ./cpanfile
COPY APIProxy/cpanfile ./APIProxy/cpanfile
RUN cpanm --notest --mirror https://cpan.metacpan.org --mirror-only \
    --with-configure --with-feature=server --installdeps .

COPY APIProxy ./APIProxy

ENV DANCER_ENVIRONMENT=cloud_run \
    PLACK_ENV=production \
    PORT=8080 \
    WORKERS=2

RUN useradd --system --uid 10001 --no-create-home appuser
USER appuser

EXPOSE 8080
CMD ["sh", "-c", "exec starman --listen \"0.0.0.0:${PORT:-8080}\" --workers \"${WORKERS:-2}\" --preload-app APIProxy/bin/app.psgi"]
