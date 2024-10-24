FROM kong-image
#FROM kong/kong-gateway:3.8
# Ensure any patching steps are executed as root user
USER root

# Add custom plugin to the image
COPY ./kong/plugins/my-plugin /usr/local/share/lua/5.1/kong/plugins/my-plugin
ENV KONG_PLUGINS=bundled,my-plugin

ENV KONG_LOG_LEVEL=debug

RUN luarocks install lua-resty-timer-ng

# Ensure kong user is selected for image execution
USER kong

# Run kong
ENTRYPOINT ["/docker-entrypoint.sh"]
EXPOSE 8000 8443 8001 8444
STOPSIGNAL SIGQUIT
HEALTHCHECK --interval=10s --timeout=10s --retries=10 CMD kong health
CMD ["kong", "docker-start"]