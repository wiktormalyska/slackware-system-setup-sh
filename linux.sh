#!/bin/bash

set -e

PATCH_DIR="/root/patches"
LOG_PATCHES="/var/log/packages/"
USERNAME="wiktor"
SLACKWARE_MIRROR="http://ftp.slackware.pl/pub/slackware/slackware64-15.0"
PATCHES_URL="$SLACKWARE_MIRROR/patches/packages"

slackpkg update gpg

echo "=== 1. Updating system ==="

# Tworzenie katalogu na patche
mkdir -p "$PATCH_DIR"
cd "$PATCH_DIR"

# Pobieranie listy dostępnych patchy z serwera
echo "Pobieranie listy dostępnych patchy..."
wget -q -O - "$PATCHES_URL/" | grep -o 'href="[^"]*\.t[xg]z"' | cut -d '"' -f 2 > available_patches.txt

# Filtrowanie zainstalowanych pakietów (bez kernela)
echo "Tworzenie listy zainstalowanych pakietów..."
installed_pkgs=$(ls $LOG_PATCHES | grep -v 'kernel' | while read -r pkg; do
    base_name=$(echo "$pkg" | rev | cut -d '-' -f4- | rev)
    echo "$base_name"
done | sort -u)

# Dodanie firefox do listy
installed_pkgs=$( (echo "$installed_pkgs"; echo "firefox") | sort -u)

# Pobieranie patchy tylko dla zainstalowanych pakietów
echo "Pobieranie patchy dla zainstalowanych pakietów..."
for pkg in $installed_pkgs; do
    # Szukanie odpowiedniego patcha dla pakietu
    patch_file=$(grep -m1 "^${pkg}-" available_patches.txt || echo "")
    
    if [ -n "$patch_file" ]; then
        echo "Znaleziono patch dla $pkg: $patch_file"
        if [ ! -f "$patch_file" ]; then
            wget -q --show-progress "$PATCHES_URL/$patch_file"
        else
            echo "Patch $patch_file już istnieje, pomijam."
        fi
    else
        echo "Brak patcha dla $pkg"
    fi
done

# Odrębna obsługa firefox, jeśli nie został znaleziony w patchach
if ! ls firefox-*.t?z >/dev/null 2>&1; then
    echo "Pobieranie Firefox z głównego repozytorium..."
    firefox_pkg=$(wget -q -O - "$SLACKWARE_MIRROR/extra/" | grep -o 'href="[^"]*firefox[^"]*\.t[xg]z"' | cut -d '"' -f 2 | sort -V | tail -n1)
    if [ -n "$firefox_pkg" ]; then
        wget -q --show-progress "$SLACKWARE_MIRROR/extra/$firefox_pkg"
    else
        echo "Nie można znaleźć pakietu Firefox"
    fi
fi

echo "Lista pobranych patchy:"
ls -la *.t?z 2>/dev/null || echo "Brak pobranych patchy"

# 1c - Instalacja poprawek
echo "=== Instalowanie patchy ==="
for pkg in *.t?z; do
    if [ -f "$pkg" ]; then
        echo "Instalowanie $pkg..."
        # Wyłącz zatrzymywanie na błędach dla instalacji pakietów
        set +e
        upgradepkg "$pkg"
        
        # Jeśli instalacja nie powiodła się, spróbuj użyć slackpkg
        if [ $? -ne 0 ]; then
            package_name=$(basename "$pkg" | sed 's/-[^-]*-[^-]*-[^-]*\.t[xg]z$//')
            echo "Instalacja przez upgradepkg nie powiodła się dla $package_name, próbuję przez slackpkg install..."
            slackpkg install "$package_name"
            
            if [ $? -ne 0 ]; then
                echo "UWAGA: Nie udało się zainstalować pakietu $package_name żadną metodą!"
            else
                echo "Pakiet $package_name zainstalowany pomyślnie przez slackpkg install."
            fi
        fi
        # Przywróć zatrzymywanie na błędach
        set -e
    fi
done

# 2a - Ustawianie strefy czasowej
echo "=== 2. Konfiguracja ==="
echo "Ustawianie strefy czasowej..."
ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
echo "Europe/Warsaw" > /etc/timezone
hwclock --systohc

# 2b - Konfiguracja SSH
echo "Konfiguracja serwera SSH..."
if ! which sshd >/dev/null; then
    echo "Instalowanie serwera SSH..."
    slackpkg install openssh
fi

# Dodanie SSH do autostartu
cat > /etc/rc.d/rc.sshd << EOF
#!/bin/sh
# Start/stop/restart the SSH daemon

ssh_start() {
  if [ -x /usr/sbin/sshd ]; then
    echo "Starting SSH daemon:  /usr/sbin/sshd"
    /usr/sbin/sshd
  fi
}

ssh_stop() {
  killall sshd
}

ssh_restart() {
  ssh_stop
  sleep 1
  ssh_start
}

case "\$1" in
'start')
  ssh_start
  ;;
'stop')
  ssh_stop
  ;;
'restart')
  ssh_restart
  ;;
*)
  ssh_start
esac
EOF

chmod +x /etc/rc.d/rc.sshd

# Dodanie uruchomienia SSH do rc.local
if ! grep -q "/etc/rc.d/rc.sshd start" /etc/rc.d/rc.local; then
    echo "/etc/rc.d/rc.sshd start" >> /etc/rc.d/rc.local
fi

# 2c - Konfiguracja firewalla
echo "Konfiguracja firewalla..."
cat > /etc/rc.d/rc.firewall << EOF
#!/bin/sh
# Prosty skrypt firewalla

# Czyszczenie wszystkich istniejących reguł
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Ustawienie domyślnych polityk
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Zezwól na lokalną komunikację
iptables -A INPUT -i lo -j ACCEPT

# Zezwól na połączenia zwrotne z już nawiązanych połączeń
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Zezwól na SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Zezwól na ICMP (ping)
iptables -A INPUT -p icmp -j ACCEPT

# Zapisz reguły
iptables-save > /etc/iptables.rules
EOF

chmod +x /etc/rc.d/rc.firewall

# Dodanie uruchomienia firewalla do rc.local
if ! grep -q "/etc/rc.d/rc.firewall" /etc/rc.d/rc.local; then
    echo "/etc/rc.d/rc.firewall" >> /etc/rc.d/rc.local
fi

# Uruchomienie firewalla
/etc/rc.d/rc.firewall

# 3a - Usunięcie użytkownika guest
echo "=== 3. Zarządzanie użytkownikami ==="
echo "Usuwanie użytkownika guest..."
if id guest &>/dev/null; then
    userdel -r guest
fi

# 3b - Dodanie nowego użytkownika
echo "Dodawanie użytkownika $USERNAME..."
if id "$USERNAME" &>/dev/null; then
    echo "Użytkownik $USERNAME już istnieje, pomijam tworzenie konta."
else
    useradd -m -s /bin/bash "$USERNAME"
    echo -e "password\npassword" | passwd "$USERNAME"
    usermod -aG wheel "$USERNAME"
    echo "Utworzono użytkownika $USERNAME."
fi

# 3c i 3d - Usuwanie wpisów Chrome z menu
echo "Usuwanie wpisów Chrome z menu..."

# Usunięcie z menu pulpitu
if [ -f "/usr/share/applications/chrome.desktop" ]; then
    rm /usr/share/applications/chrome.desktop
fi

# Usunięcie z menu zielonej ikony (xlunch)
XLUNCH_CONFIG="/etc/xlunch/entries.dsv"
if [ -f "$XLUNCH_CONFIG" ]; then
    grep -v "Chrome" "$XLUNCH_CONFIG" > "$XLUNCH_CONFIG.tmp"
    mv "$XLUNCH_CONFIG.tmp" "$XLUNCH_CONFIG"
fi

# 4a - Pobranie źródeł Qcl
echo "=== 4. Instalacja Qcl ==="
cd /tmp
echo "Pobieranie źródeł Qcl..."
wget http://tph.tuwien.ac.at/~oemer/tgz/qcl-0.6.7.tgz
tar xzf qcl-0.6.7.tgz
cd qcl-0.6.7

# 4b - Modyfikacja Makefile i instalacja wymaganych narzędzi
echo "Instalowanie narzędzi deweloperskich..."

# Wyłącz krytyczne błędy dla sekcji instalacji pakietów
set +e

# Lista wymaganych pakietów deweloperskich, w tym guile dla libguile-3.0
required_packages="gcc gcc-g++ make bison flex guile guile-dev readline readline-devel ncurses ncurses-devel gc libgc boehm-gc glibc-devel libc-devel kernel-headers kernel-source binutils"
#!/bin/bash

set -e

PATCH_DIR="/root/patches"
LOG_PATCHES="/var/log/packages/"
USERNAME="wiktor"
SLACKWARE_MIRROR="http://ftp.slackware.pl/pub/slackware/slackware64-15.0"
PATCHES_URL="$SLACKWARE_MIRROR/patches/packages"

slackpkg update gpg

echo "=== 1. Updating system ==="

# Tworzenie katalogu na patche
mkdir -p "$PATCH_DIR"
cd "$PATCH_DIR"

# Pobieranie listy dostępnych patchy z serwera
echo "Pobieranie listy dostępnych patchy..."
wget -q -O - "$PATCHES_URL/" | grep -o 'href="[^"]*\.t[xg]z"' | cut -d '"' -f 2 > available_patches.txt

# Filtrowanie zainstalowanych pakietów (bez kernela)
echo "Tworzenie listy zainstalowanych pakietów..."
installed_pkgs=$(ls $LOG_PATCHES | grep -v 'kernel' | while read -r pkg; do
    base_name=$(echo "$pkg" | rev | cut -d '-' -f4- | rev)
    echo "$base_name"
done | sort -u)

# Dodanie firefox do listy
installed_pkgs=$( (echo "$installed_pkgs"; echo "firefox") | sort -u)

# Pobieranie patchy tylko dla zainstalowanych pakietów
echo "Pobieranie patchy dla zainstalowanych pakietów..."
for pkg in $installed_pkgs; do
    # Szukanie odpowiedniego patcha dla pakietu
    patch_file=$(grep -m1 "^${pkg}-" available_patches.txt || echo "")
    
    if [ -n "$patch_file" ]; then
        echo "Znaleziono patch dla $pkg: $patch_file"
        if [ ! -f "$patch_file" ]; then
            wget -q --show-progress "$PATCHES_URL/$patch_file"
        else
            echo "Patch $patch_file już istnieje, pomijam."
        fi
    else
        echo "Brak patcha dla $pkg"
    fi
done

# Odrębna obsługa firefox, jeśli nie został znaleziony w patchach
if ! ls firefox-*.t?z >/dev/null 2>&1; then
    echo "Pobieranie Firefox z głównego repozytorium..."
    firefox_pkg=$(wget -q -O - "$SLACKWARE_MIRROR/extra/" | grep -o 'href="[^"]*firefox[^"]*\.t[xg]z"' | cut -d '"' -f 2 | sort -V | tail -n1)
    if [ -n "$firefox_pkg" ]; then
        wget -q --show-progress "$SLACKWARE_MIRROR/extra/$firefox_pkg"
    else
        echo "Nie można znaleźć pakietu Firefox"
    fi
fi

echo "Lista pobranych patchy:"
ls -la *.t?z 2>/dev/null || echo "Brak pobranych patchy"

# 1c - Instalacja poprawek
echo "=== Instalowanie patchy ==="
for pkg in *.t?z; do
    if [ -f "$pkg" ]; then
        echo "Instalowanie $pkg..."
        # Wyłącz zatrzymywanie na błędach dla instalacji pakietów
        set +e
        upgradepkg "$pkg"
        
        # Jeśli instalacja nie powiodła się, spróbuj użyć slackpkg
        if [ $? -ne 0 ]; then
            package_name=$(basename "$pkg" | sed 's/-[^-]*-[^-]*-[^-]*\.t[xg]z$//')
            echo "Instalacja przez upgradepkg nie powiodła się dla $package_name, próbuję przez slackpkg install..."
            slackpkg install "$package_name"
            
            if [ $? -ne 0 ]; then
                echo "UWAGA: Nie udało się zainstalować pakietu $package_name żadną metodą!"
            else
                echo "Pakiet $package_name zainstalowany pomyślnie przez slackpkg install."
            fi
        fi
        # Przywróć zatrzymywanie na błędach
        set -e
    fi
done

# 2a - Ustawianie strefy czasowej
echo "=== 2. Konfiguracja ==="
echo "Ustawianie strefy czasowej..."
ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
echo "Europe/Warsaw" > /etc/timezone
hwclock --systohc

# 2b - Konfiguracja SSH
echo "Konfiguracja serwera SSH..."
if ! which sshd >/dev/null; then
    echo "Instalowanie serwera SSH..."
    slackpkg install openssh
fi

# Dodanie SSH do autostartu
cat > /etc/rc.d/rc.sshd << EOF
#!/bin/sh
# Start/stop/restart the SSH daemon

ssh_start() {
  if [ -x /usr/sbin/sshd ]; then
    echo "Starting SSH daemon:  /usr/sbin/sshd"
    /usr/sbin/sshd
  fi
}

ssh_stop() {
  killall sshd
}

ssh_restart() {
  ssh_stop
  sleep 1
  ssh_start
}

case "\$1" in
'start')
  ssh_start
  ;;
'stop')
  ssh_stop
  ;;
'restart')
  ssh_restart
  ;;
*)
  ssh_start
esac
EOF

chmod +x /etc/rc.d/rc.sshd

# Dodanie uruchomienia SSH do rc.local
if ! grep -q "/etc/rc.d/rc.sshd start" /etc/rc.d/rc.local; then
    echo "/etc/rc.d/rc.sshd start" >> /etc/rc.d/rc.local
fi

# 2c - Konfiguracja firewalla
echo "Konfiguracja firewalla..."
cat > /etc/rc.d/rc.firewall << EOF
#!/bin/sh
# Prosty skrypt firewalla

# Czyszczenie wszystkich istniejących reguł
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Ustawienie domyślnych polityk
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Zezwól na lokalną komunikację
iptables -A INPUT -i lo -j ACCEPT

# Zezwól na połączenia zwrotne z już nawiązanych połączeń
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Zezwól na SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Zezwól na ICMP (ping)
iptables -A INPUT -p icmp -j ACCEPT

# Zapisz reguły
iptables-save > /etc/iptables.rules
EOF

chmod +x /etc/rc.d/rc.firewall

# Dodanie uruchomienia firewalla do rc.local
if ! grep -q "/etc/rc.d/rc.firewall" /etc/rc.d/rc.local; then
    echo "/etc/rc.d/rc.firewall" >> /etc/rc.d/rc.local
fi

# Uruchomienie firewalla
/etc/rc.d/rc.firewall

# 3a - Usunięcie użytkownika guest
echo "=== 3. Zarządzanie użytkownikami ==="
echo "Usuwanie użytkownika guest..."
if id guest &>/dev/null; then
    userdel -r guest
fi

# 3b - Dodanie nowego użytkownika
echo "Dodawanie użytkownika $USERNAME..."
if id "$USERNAME" &>/dev/null; then
    echo "Użytkownik $USERNAME już istnieje, pomijam tworzenie konta."
else
    useradd -m -s /bin/bash "$USERNAME"
    echo -e "password\npassword" | passwd "$USERNAME"
    usermod -aG wheel "$USERNAME"
    echo "Utworzono użytkownika $USERNAME."
fi

# 3c i 3d - Usuwanie wpisów Chrome z menu
echo "Usuwanie wpisów Chrome z menu..."

# Usunięcie z menu pulpitu
if [ -f "/usr/share/applications/chrome.desktop" ]; then
    rm /usr/share/applications/chrome.desktop
fi

# Usunięcie z menu zielonej ikony (xlunch)
XLUNCH_CONFIG="/etc/xlunch/entries.dsv"
if [ -f "$XLUNCH_CONFIG" ]; then
    grep -v "Chrome" "$XLUNCH_CONFIG" > "$XLUNCH_CONFIG.tmp"
    mv "$XLUNCH_CONFIG.tmp" "$XLUNCH_CONFIG"
fi

# 4a - Pobranie źródeł Qcl
echo "=== 4. Instalacja Qcl ==="
cd /tmp
echo "Pobieranie źródeł Qcl..."
wget http://tph.tuwien.ac.at/~oemer/tgz/qcl-0.6.7.tgz
tar xzf qcl-0.6.7.tgz
cd qcl-0.6.7

# 4b - Modyfikacja Makefile i instalacja wymaganych narzędzi
echo "Instalowanie narzędzi deweloperskich..."

# Wyłącz krytyczne błędy dla sekcji instalacji pakietów
set +e

# Lista wymaganych pakietów deweloperskich, w tym guile dla libguile-3.0
required_packages="gcc gcc-g++ make bison flex guile guile-dev readline readline-devel ncurses ncurses-devel gc libgc boehm-gc glibc-devel libc-devel kernel-headers kernel-source binutils"
slackpkg install binutils plotutils xorgproto libXt aaa_glibc autoconfig automake m4


for pkg in $required_packages; do
    echo "Próba instalacji pakietu $pkg..."
    slackpkg -batch=on -default_answer=y install $pkg

    # Sprawdź alternatywne nazwy pakietów, jeśli standardowa nazwa nie zadziała
    if [ $? -ne 0 ]; then
        echo "Nie znaleziono pakietu $pkg, próbuję alternatywnych nazw..."
        installed=0
        case $pkg in
            guile)
                slackpkg -batch=on -default_answer=y install guile3 && installed=1 || \
                slackpkg -batch=on -default_answer=y install guile2 && installed=1
                ;;
            guile-dev)
                slackpkg -batch=on -default_answer=y install guile-devel && installed=1 || \
                slackpkg -batch=on -default_answer=y install guile3-devel && installed=1 || \
                slackpkg -batch=on -default_answer=y install guile2-devel && installed=1
                ;;
            *)
                echo "Brak alternatyw dla pakietu $pkg"
                installed=0
                ;;
        esac
        
        # Jeśli żadna metoda nie zadziałała, spróbuj bezpośrednio slackpkg install
        if [ $installed -eq 0 ]; then
            echo "Próba bezpośredniej instalacji pakietu przez slackpkg..."
            slackpkg install $pkg
            if [ $? -ne 0 ]; then
                echo "Nie udało się zainstalować pakietu $pkg żadną metodą"
            fi
        fi
    fi
done

set -e

# Sprawdzenie, czy istnieje libguile-3.0.so
if ! ldconfig -p | grep -q libguile-3.0.so; then
    echo "OSTRZEŻENIE: Biblioteka libguile-3.0.so nadal nie jest dostępna!"
    echo "Próba ręcznego pobrania i instalacji pakietu guile..."
    
    # Ręczne pobranie i instalacja guile
    cd /tmp
    
    # Sprawdź dostępne pakiety guile w repozytoriach Slackware
    echo "Szukam pakietów guile w repozytoriach..."
    guile_packages=$(wget -q -O - "$SLACKWARE_MIRROR/slackware64/" | grep -o 'href="[^"]*guile[^"]*\.t[xg]z"' | cut -d '"' -f 2)
    
    if [ -n "$guile_packages" ]; then
        # Pobierz i zainstaluj pierwszy znaleziony pakiet guile
        guile_pkg=$(echo "$guile_packages" | head -n1)
        wget -q --show-progress "$SLACKWARE_MIRROR/slackware64/$guile_pkg"
        installpkg "$guile_pkg"
        rm -f "$guile_pkg"
    else
        echo "Nie znaleziono pakietu guile w repozytoriach."
    fi
fi

# Wróć do katalogu qcl
cd /tmp/qcl-0.6.7

# Edycja Makefile - wykomentowanie libplotter
echo "Modyfikowanie Makefile..."
sed -i 's/^PLOTTER/#PLOTTER/' Makefile
sed -i 's/^PLIBS/#PLIBS/' Makefile
sed -i 's/^PHEAD/#PHEAD/' Makefile

# Dodatkowo, możemy zakomentować część kodu korzystającą z guile, jeśli nie jest krytyczna
if [ -f "qcl.h" ]; then
    echo "Modyfikuję qcl.h, aby usunąć zależność od libguile..."
    # Utwórz kopię zapasową
    cp qcl.h qcl.h.bak
    
    # Zakomentuj linię z #include <libguile.h>, jeśli istnieje
    sed -i 's/#include <libguile.h>/\/\/#include <libguile.h>/' qcl.h
    
    # Można też dodać inne modyfikacje, jeśli są potrzebne
fi

# 4c - Kompilacja z obsługą błędów
echo "Kompilowanie Qcl..."
make || {
    echo "Wystąpił błąd podczas kompilacji. Próbuję alternatywne podejście..."
    
    # Sprawdź dokładnie błędy kompilacji
    echo "Analiza błędów kompilacji..."
    
    # Ręczna kompilacja z pominięciem problematycznych elementów
    echo "Próba ręcznej kompilacji..."
    
    # Utwórz prostszą wersję Makefile bez zależności od guile
    cat > Makefile.simple << EOF
CC = gcc
CXX = g++
CFLAGS = -g -O2 -Wall
CXXFLAGS = -g -O2 -Wall
LDFLAGS = -lm -lreadline -lncurses

OBJS = parse.o lex.o syntax.o qcl.o quheap.o qureg.o qusim.o options.o

qcl: \$(OBJS)
    \$(CXX) -o qcl \$(OBJS) \$(LDFLAGS)

clean:
    rm -f *.o qcl
EOF
    
    # Kompilacja z użyciem prostszego Makefile
    make -f Makefile.simple
}

# Sprawdź, czy qcl został skompilowany
if [ ! -f "qcl" ]; then
    echo "BŁĄD: Kompilacja Qcl nie powiodła się!"
    exit 1
fi

# 1d i 3e - Zapisanie zmian (persistent changes)
echo "=== Zapisywanie zmian persistent ==="
# Zapisanie zmian w systemie
savechanges /mnt/sda1/slax/changes.dat

echo "Zadanie zakończone pomyślnie!"
for pkg in $required_packages; do
    echo "Próba instalacji pakietu $pkg..."
    slackpkg -batch=on -default_answer=y install $pkg
    
    # Sprawdź alternatywne nazwy pakietów, jeśli standardowa nazwa nie zadziała
    if [ $? -ne 0 ]; then
        echo "Nie znaleziono pakietu $pkg, próbuję alternatywnych nazw..."
        installed=0
        case $pkg in
            guile)
                slackpkg -batch=on -default_answer=y install guile3 && installed=1 || \
                slackpkg -batch=on -default_answer=y install guile2 && installed=1
                ;;
            guile-dev)
                slackpkg -batch=on -default_answer=y install guile-devel && installed=1 || \
                slackpkg -batch=on -default_answer=y install guile3-devel && installed=1 || \
                slackpkg -batch=on -default_answer=y install guile2-devel && installed=1
                ;;
            *)
                echo "Brak alternatyw dla pakietu $pkg"
                installed=0
                ;;
        esac
        
        # Jeśli żadna metoda nie zadziałała, spróbuj bezpośrednio slackpkg install
        if [ $installed -eq 0 ]; then
            echo "Próba bezpośredniej instalacji pakietu przez slackpkg..."
            slackpkg install $pkg
            if [ $? -ne 0 ]; then
                echo "Nie udało się zainstalować pakietu $pkg żadną metodą"
            fi
        fi
    fi
done

set -e

# Sprawdzenie, czy istnieje libguile-3.0.so
if ! ldconfig -p | grep -q libguile-3.0.so; then
    echo "OSTRZEŻENIE: Biblioteka libguile-3.0.so nadal nie jest dostępna!"
    echo "Próba ręcznego pobrania i instalacji pakietu guile..."
    
    # Ręczne pobranie i instalacja guile
    cd /tmp
    
    # Sprawdź dostępne pakiety guile w repozytoriach Slackware
    echo "Szukam pakietów guile w repozytoriach..."
    guile_packages=$(wget -q -O - "$SLACKWARE_MIRROR/slackware64/" | grep -o 'href="[^"]*guile[^"]*\.t[xg]z"' | cut -d '"' -f 2)
    
    if [ -n "$guile_packages" ]; then
        # Pobierz i zainstaluj pierwszy znaleziony pakiet guile
        guile_pkg=$(echo "$guile_packages" | head -n1)
        wget -q --show-progress "$SLACKWARE_MIRROR/slackware64/$guile_pkg"
        installpkg "$guile_pkg"
        rm -f "$guile_pkg"
    else
        echo "Nie znaleziono pakietu guile w repozytoriach."
    fi
fi

# Wróć do katalogu qcl
cd /tmp/qcl-0.6.7

# Edycja Makefile - wykomentowanie libplotter
echo "Modyfikowanie Makefile..."
sed -i 's/^PLOTTER/#PLOTTER/' Makefile
sed -i 's/^PLIBS/#PLIBS/' Makefile
sed -i 's/^PHEAD/#PHEAD/' Makefile

# Dodatkowo, możemy zakomentować część kodu korzystającą z guile, jeśli nie jest krytyczna
if [ -f "qcl.h" ]; then
    echo "Modyfikuję qcl.h, aby usunąć zależność od libguile..."
    # Utwórz kopię zapasową
    cp qcl.h qcl.h.bak
    
    # Zakomentuj linię z #include <libguile.h>, jeśli istnieje
    sed -i 's/#include <libguile.h>/\/\/#include <libguile.h>/' qcl.h
    
    # Można też dodać inne modyfikacje, jeśli są potrzebne
fi

# 4c - Kompilacja z obsługą błędów
echo "Kompilowanie Qcl..."
make || {
    echo "Wystąpił błąd podczas kompilacji. Próbuję alternatywne podejście..."
    
    # Sprawdź dokładnie błędy kompilacji
    echo "Analiza błędów kompilacji..."
    
    # Ręczna kompilacja z pominięciem problematycznych elementów
    echo "Próba ręcznej kompilacji..."
    
    # Utwórz prostszą wersję Makefile bez zależności od guile
    cat > Makefile.simple << EOF
CC = gcc
CXX = g++
CFLAGS = -g -O2 -Wall
CXXFLAGS = -g -O2 -Wall
LDFLAGS = -lm -lreadline -lncurses

OBJS = parse.o lex.o syntax.o qcl.o quheap.o qureg.o qusim.o options.o

qcl: \$(OBJS)
    \$(CXX) -o qcl \$(OBJS) \$(LDFLAGS)

clean:
    rm -f *.o qcl
EOF
    
    # Kompilacja z użyciem prostszego Makefile
    make -f Makefile.simple
}

# Sprawdź, czy qcl został skompilowany
if [ ! -f "qcl" ]; then
    echo "BŁĄD: Kompilacja Qcl nie powiodła się!"
    exit 1
fi

# 1d i 3e - Zapisanie zmian (persistent changes)
echo "=== Zapisywanie zmian persistent ==="
# Zapisanie zmian w systemie
savechanges /mnt/sda1/slax/changes.dat

echo "Zadanie zakończone pomyślnie!"