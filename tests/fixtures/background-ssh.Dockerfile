FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server sudo python3 && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash fixture && echo 'fixture:fixture-password' | chpasswd \
    && echo 'root:root-password' | chpasswd && usermod -aG sudo fixture \
    && mkdir -p /run/sshd && ssh-keygen -A \
    && printf 'PasswordAuthentication yes\nPermitRootLogin no\nUsePAM yes\n' > /etc/ssh/sshd_config.d/fixture.conf
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
