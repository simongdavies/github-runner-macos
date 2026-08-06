. tart-common.sh

tart clone ghcr.io/cirruslabs/ubuntu:latest kernel-builder
tart set kernel-builder --cpu 10 --memory 8192 --disk-size 100
mkdir -p ./debs
tart run --no-graphics --dir=debs:./debs kernel-builder &
sleep 10
ip=$(tart ip kernel-builder)
SSHPASS="$TART_GUEST_PASSWORD" sshpass -e ssh "${TART_SSH_OPTS[@]}" \
            "${TART_GUEST_USER}@${ip}" \
            sudo bash -s <<'BUILD'
  hostname
  mkdir -p /virtiofs
  mount -t virtiofs com.apple.virtio-fs.automount /virtiofs
  mkdir -p /debs
  mount --bind /virtiofs/debs /debs

  # Prepare dependencies
  sed 's/^Types: deb$/\0 deb-src/' /etc/apt/sources.list.d/ubuntu.sources -i
  apt update
  apt build-dep -y linux linux-image-unsigned-$(uname -r)
  apt install -y libncurses-dev gawk flex bison openssl libssl-dev dkms libelf-dev libudev-dev libpci-dev libiberty-dev autoconf llvm cmake devscripts fakeroot
  # Install a newer version of pahole, because linux won't build with the version in here
  #curl https://git.kernel.org/pub/scm/devel/pahole/pahole.git/snapshot/pahole-1.31.tar.gz | tar -xz
  git clone https://git.kernel.org/pub/scm/devel/pahole/pahole.git -b v1.31
  cd pahole
  mkdir build
  cd build
  cmake ..
  make install
  cd ../..
  export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib
  # Build Linux pkgs
  apt source linux-image-unsigned-$(uname -r)
  cd $(find . -maxdepth 1 -iname 'linux-*' -type d)
  patch -p0 <<'PATCH'
--- arch/arm64/include/asm/cpufeature.h	2026-07-30 20:57:07.600783813 +0000
+++ arch/arm64/include/asm/cpufeature.h	2026-07-30 20:58:22.972842361 +0000
@@ -941,18 +941,8 @@
 
 static inline unsigned int get_vmid_bits(u64 mmfr1)
 {
-	int vmid_bits;
-
-	vmid_bits = cpuid_feature_extract_unsigned_field(mmfr1,
-						ID_AA64MMFR1_EL1_VMIDBits_SHIFT);
-	if (vmid_bits == ID_AA64MMFR1_EL1_VMIDBits_16)
-		return 16;
-
-	/*
-	 * Return the default here even if any reserved
-	 * value is fetched from the system register.
-	 */
-	return 8;
+	/* Limit the number of VMIDs used to allow more concurrent VMs on HVF */
+	return 5;
 }
 
 s64 arm64_ftr_safe_value(const struct arm64_ftr_bits *ftrp, s64 new, s64 cur);
PATCH
  EMAIL=root@localhost dch -l +vmid5 'Restrict VMIDs to 5 bits'
  head -n 10 debian/changelog
  find debian/scripts -type f -exec chmod a+x \{\} \;
  fakeroot debian/rules binary-headers binary-generic binary-perarch
  cd ..
  # Install Linux pkgs
  #DEBIAN_FRONTEND=noninteractive dpkg -i ../linux*.deb
  cp *vmid5*.deb /debs
  shutdown -h now
BUILD
