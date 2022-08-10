ARG ALPINE_VERSION
FROM registry.kyso.io/docker/alpine:$ALPINE_VERSION
LABEL maintainer="Sergio Talens-Oliag <sto@kyso.io>"
RUN apk update &&\
 apk add --no-cache mysecureshell util-linux-misc shadow pwgen &&\
 sed -i -e "s|^.*\(AuthorizedKeysFile\).*$|\1 /etc/ssh/auth_keys/%u|"\
 /etc/ssh/sshd_config &&\
 mkdir /etc/ssh/auth_keys &&\
 cat /dev/null > /etc/motd &&\
 rm -rf /var/cache/apk/*
COPY sftp_config /etc/ssh/
COPY entrypoint.sh /
EXPOSE 22
VOLUME /sftp
ENTRYPOINT ["/entrypoint.sh"]
CMD ["server"]
