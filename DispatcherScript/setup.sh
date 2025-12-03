#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Devi eseguire lo script come root (usa sudo)."
  exit 1
fi

USERNAME="dispatcher"
USERHOME="/home/$USERNAME"
ZIP_URL="https://github.com/gtanzi92/ConnectSuiteScript/raw/refs/heads/main/DispatcherScript/Dispatcher.zip"
ZIP_FILE="$USERHOME/Dispatcher.zip"

# Creazione utente se non esiste
if id "$USERNAME" &>/dev/null; then
  echo "L'utente $USERNAME esiste già."
else
  echo "Creazione utente $USERNAME..."
  useradd -m -s /bin/bash "$USERNAME"

  echo "Inserisci la password per $USERNAME:"
  read -s PASSWORD
  echo "$USERNAME:$PASSWORD" | chpasswd

  echo "Utente $USERNAME creato con successo!"
fi

# Aggiungo l'utente al gruppo sudo
usermod -aG sudo "$USERNAME"
echo "Utente $USERNAME aggiunto al gruppo sudo!"

# Creo la cartella /opt/dispatcher
mkdir -p /opt/dispatcher
chown "$USERNAME":"$USERNAME" /opt/dispatcher
echo "Cartella /opt/dispatcher creata e assegnata a $USERNAME."

# Modifico il file sshd_config per permettere login root
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"

if grep -q "^PermitRootLogin" "$SSHD_CONFIG"; then
  sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
else
  echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
fi

systemctl restart ssh
echo "Configurazione SSH aggiornata: accesso root abilitato."

# Aggiorno pacchetti e installo unzip + curl
echo "Aggiornamento lista pacchetti..."
apt update -y
echo "Aggiornamento pacchetti installati..."
apt upgrade -y
echo "Installazione di unzip e curl..."
apt install -y unzip curl

# Scarico Dispatcher.zip nella home dell'utente dispatcher
echo "Scarico Dispatcher.zip nella home di $USERNAME..."
wget -O "$ZIP_FILE" "$ZIP_URL"
chown "$USERNAME":"$USERNAME" "$ZIP_FILE"

# Estraggo il contenuto nella root /
echo "Estrazione del contenuto di Dispatcher.zip in / ..."
unzip -o "$ZIP_FILE" -d /

# Rendo eseguibile Connect.Dispatcher
echo "Rendo eseguibile Connect.Dispatcher..."
chmod +x /opt/dispatcher/Connect.Dispatcher

# Attivo e avvio il servizio dispatcher.service
echo "Ricarico i servizi systemd..."
systemctl daemon-reload
systemctl enable dispatcher.service
systemctl restart dispatcher.service
journalctl -u dispatcher.service -n 20 --no-pager

# Installo e configuro nftables
echo "Installazione di nftables..."
apt install -y nftables

echo "Abilitazione e avvio del servizio nftables..."
systemctl enable nftables
systemctl start nftables

echo "Aggiunta regole firewall per porta 8080..."
nft add rule inet filter input tcp dport 8080 accept
nft add rule inet filter output tcp sport 8080 accept

echo "Configurazione nftables completata!"

# Interazione per configurare devices.json
DEVICE_JSON="/opt/dispatcher/devices.json"

echo "Configuriamo il file $DEVICE_JSON"

# Chiedo i valori all'utente
read -p "Inserisci l'indirizzo IP: " IPADDR
read -p "Inserisci il numero di serie: " SERIAL
echo "Seleziona il tipo di configurazione:"
echo "0 = custom"
echo "1 = RCH"
echo "2 = Epson"
read -p "Tipo: " TYPE

# Validazione minima sul tipo
if [[ "$TYPE" != "0" && "$TYPE" != "1" && "$TYPE" != "2" ]]; then
  echo "Valore non valido, imposto default = 0 (custom)"
  TYPE=0
fi

# Scrivo il nuovo JSON nel file
cat > "$DEVICE_JSON" <<EOF
{"Main":{"Address":"$IPADDR","IdentificationNumber":"$SERIAL","Type":$TYPE}}
EOF

echo "File $DEVICE_JSON aggiornato con successo!"



echo "=== Configurazione IP statico ==="

# Chiedi i parametri all'utente
read -p "Nome interfaccia (es. eth0 o wlan0): " IFACE
read -p "Indirizzo IP (es. 192.168.1.50): " IPADDR
read -p "Subnet mask in CIDR (es. 24 per 255.255.255.0): " CIDR
read -p "Gateway (es. 192.168.1.1): " GATEWAY
read -p "DNS (es. 8.8.8.8 1.1.1.1): " DNS

# Percorso file di configurazione
CONF_FILE="/etc/systemd/network/10-${IFACE}.network"

echo "Creo il file di configurazione: $CONF_FILE"

# Scrivi il file di configurazione
sudo bash -c "cat > $CONF_FILE" <<EOF
[Match]
Name=$IFACE

[Network]
Address=${IPADDR}/${CIDR}
Gateway=$GATEWAY
EOF

# Aggiungi DNS se specificati
for d in $DNS; do
    echo "DNS=$d" | sudo tee -a $CONF_FILE > /dev/null
done

echo "File creato con successo!"

sudo systemctl enable systemd-networkd
sudo systemctl restart systemd-networkd

echo "=== Configurazione completata ==="


# Installo servizio connect Raspberrypi e lo faccio partire

echo "Installazione servizio Connect RaspberryPi"
apt install rpi-connect-lite

sudo rpi-connect on
sudo enable rpi-connect

loginctl enable-linger dispatcher

echo "Controllo aggiornamenti"
apt install --only-upgrade rpi-connect
