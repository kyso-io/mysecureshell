ARG ALPINE_VERSION=3.16.2

FROM alpine:$ALPINE_VERSION as builder
LABEL maintainer="Sergio Talens-Oliag <sto@kyso.io>"
RUN apk update &&\
 apk add --no-cache alpine-sdk git musl-dev &&\
 git clone https://github.com/sto/mysecureshell.git &&\
 cd mysecureshell &&\
 ./configure --prefix=/usr --sysconfdir=/etc --mandir=/usr/share/man\
 --localstatedir=/var --with-shutfile=/var/lib/misc/sftp.shut --with-debug=2 &&\
 make all && make install &&\
 rm -rf /var/cache/apk/*
COPY sftp_config /etc/ssh/

FROM alpine:$ALPINE_VERSION
LABEL maintainer="Sergio Talens-Oliag <sto@kyso.io>"
COPY --from=builder /usr/bin/mysecureshell /usr/bin/mysecureshell
COPY --from=builder /usr/bin/sftp-* /usr/bin/
RUN apk update &&\
 apk add --no-cache openssh shadow pwgen &&\
 sed -i -e "s|^.*\(AuthorizedKeysFile\).*$|\1 /etc/ssh/auth_keys/%u|"\
 /etc/ssh/sshd_config &&\
 mkdir /etc/ssh/auth_keys &&\
 : >/etc/motd &&\
 mkdir /fileSecrets &&\
 add-shell '/usr/bin/mysecureshell' &&\
 rm -rf /var/cache/apk/*
COPY sftp_config /etc/ssh/
RUN KUBECTL_VERSION="1.22.15" && os="linux" && arch="amd64" &&\
 url="https://dl.k8s.io/release/v$KUBECTL_VERSION/bin/$os/$arch/kubectl" &&\
 wget -q -O "/usr/local/bin/kubectl" "$url" &&\
 chmod +x "/usr/local/bin/kubectl"
COPY entrypoint.sh /
EXPOSE 22
VOLUME /sftp
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sshd"]
