# Nautobot + the lab's apps (plugins). Built on the NMS by install.sh.
ARG NAUTOBOT_IMAGE_TAG=3.2-py3.12
FROM networktocode/nautobot:${NAUTOBOT_IMAGE_TAG}

USER 0
RUN pip install --no-cache-dir \
      "nautobot-plugin-nornir>=3.2,<4" \
      "nautobot-ssot>=4.6,<5" \
      "nautobot-device-onboarding>=5.5,<6" \
      "nautobot-golden-config>=3.0,<4" \
      "nautobot-bgp-models>=3.1,<4" \
      "pynautobot>=3.1,<4"
COPY --chown=nautobot:nautobot nautobot_config.py /opt/nautobot/nautobot_config.py
USER nautobot
