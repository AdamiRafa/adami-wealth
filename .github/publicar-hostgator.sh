#!/usr/bin/env bash
# Publica o portal na HostGator por FTPS (FTP com criptografia).
# Quem chama é o .github/workflows/publicar-hostgator.yml, a cada commit na main.
#
# Precisa de FTP_SERVIDOR, FTP_USUARIO e FTP_SENHA, cadastrados como segredos do
# repositório no GitHub (nunca em arquivo, nunca em conversa). FTP_PORTA é opcional.
#
# A conta FTP tem que enxergar SÓ a pasta do portal. Mesmo assim, há uma trava: se a
# pasta remota tiver conteúdo e não tiver o arquivo marcador abaixo, nada é enviado e
# nada é apagado. Isso protege o site da empresa caso a conta FTP aponte para o lugar
# errado, porque a publicação apaga do servidor o que não existe mais no repositório.
set -euo pipefail

ORIGEM="${1:-.}"
MARCADOR=".portal-adami-captal"

for v in FTP_SERVIDOR FTP_USUARIO FTP_SENHA; do
  if [ -z "${!v:-}" ]; then echo "::error::Falta o segredo $v."; exit 1; fi
done

# 1. Monta a pasta que vai ao ar. Lista positiva: só HTML, vendor/ e .htaccess.
#    SQL, documentação e qualquer arquivo novo ficam de fora até alguém incluir aqui.
SITE="$(mktemp -d)"
trap 'rm -rf "$SITE"' EXIT
cp "$ORIGEM"/*.html "$SITE"/
cp "$ORIGEM"/.htaccess "$SITE"/
cp -R "$ORIGEM"/vendor "$SITE"/vendor
printf 'Portal Adami Captal. Esta pasta e substituida inteira a cada publicacao pelo GitHub.\nNao guarde nada aqui.\n' > "$SITE/$MARCADOR"

# 2. Conexão. Criptografia obrigatória e certificado conferido (padrão do lftp).
#    A senha vai por variável de ambiente, nunca pela linha de comando.
export LFTP_PASSWORD="$FTP_SENHA"
PREP="set cmd:fail-exit true; set ftp:ssl-force true; set ftp:ssl-protect-data true; set ftp:ssl-protect-list true; set net:max-retries 3; set net:timeout 30; set net:reconnect-interval-base 5"
ftp_cmd() {
  lftp --env-password -u "$FTP_USUARIO" -p "${FTP_PORTA:-21}" -e "$PREP; $1; bye" "ftp://$FTP_SERVIDOR"
}

# 3. Trava de segurança: só publica em pasta vazia ou que já é do portal.
#    .ftpquota, error_log, .well-known e cgi-bin são criados pela própria HostGator.
LISTA="$(ftp_cmd "cls -1a")"
ESTRANHOS="$(printf '%s\n' "$LISTA" | sed 's#/$##' | grep -v -x -E '\.|\.\.|\.ftpquota|error_log|\.well-known|cgi-bin|' || true)"
if [ -n "$ESTRANHOS" ] && ! printf '%s\n' "$ESTRANHOS" | grep -q -x -F "$MARCADOR"; then
  echo "::error::A pasta do FTP tem arquivos que não são do portal. Nada foi enviado nem apagado. Confira se a conta FTP aponta para a pasta do portal, e não para a do site."
  printf '%s\n' "$ESTRANHOS" | head -20
  exit 1
fi

# 4. Envia tudo e apaga do servidor o que saiu do repositório.
ftp_cmd "mirror --reverse --delete --no-perms --verbose --parallel=4 --exclude-glob .ftpquota --exclude-glob error_log --exclude-glob .well-known/ --exclude-glob cgi-bin/ '$SITE' ."
echo "Publicado."
