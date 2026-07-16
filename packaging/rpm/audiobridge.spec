Name:           audiobridge
Version:        %{_app_version}
Release:        1
Summary:        Wi-Fi LAN audio relay
License:        Proprietary
URL:            https://codeberg.org/SketchyLucian/audiobridge
BuildArch:      x86_64
Requires:       alsa-lib

%description
AudioBridge relays audio over a local Wi-Fi network.

%prep

%build

%install
rm -rf %{buildroot}
install -d %{buildroot}/opt/AudioBridge
cp -a %{_bundle_dir}/. %{buildroot}/opt/AudioBridge/
install -d %{buildroot}%{_bindir}
ln -s ../../opt/AudioBridge/audiobridge %{buildroot}%{_bindir}/audiobridge
install -Dpm 0644 %{_desktop_file} %{buildroot}%{_datadir}/applications/audiobridge.desktop

%files
%dir /opt/AudioBridge
/opt/AudioBridge/*
%{_bindir}/audiobridge
%{_datadir}/applications/audiobridge.desktop
