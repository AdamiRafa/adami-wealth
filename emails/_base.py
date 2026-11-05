# Gera os e-mails do Hub Adami a partir de um layout único.
# Rodar: python3 emails/_base.py
#
# - emails/redefinir-senha.html: colado no Supabase (Authentication > Emails > Templates >
#   Reset Password). {{ .ConfirmationURL }} e {{ .Email }} são variáveis do Supabase.
# - emails/boas-vindas.html: cópia de referência do e-mail de boas-vindas. Quem envia é a
#   função supabase/functions/enviar-convite/index.ts, e este script grava o modelo dentro
#   dela ({{LINK}}, {{EMAIL}} e {{SAUDACAO}} são trocados pela função na hora do envio).
# - emails/senha-funcao.html: o reset que sai pela função enviar-senha (desde 05/11/2026).
#   Mesmo texto do redefinir-senha.html, com {{LINK}} e {{EMAIL}} trocados pela função.
# - emails/agenda-manha.html: o e-mail da manhã da Agenda do CRM (função agenda-manha).
#   {{CONTEUDO}} é a lista montada pela função; {{SAUDACAO}} e {{LINK}} também.
import os, json, re
IMG = "https://adamicaptal.com.br/hub/img/"
NAVY, NAVY_D, INK, INK2, MUTED, GOLD, PAPER, LINE = "#1B3A5F", "#132B47", "#16324F", "#3C4C60", "#7A8698", "#C0A265", "#EDF0F4", "#DCE2EA"
SANS = "Helvetica, Arial, sans-serif"
SERIF = "Georgia, 'Times New Roman', serif"

def email(titulo_aba, preheader, icone, titulo, corpo, botao, depois, link="{{ .ConfirmationURL }}"):
    return f"""<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>{titulo_aba}</title>
</head>
<body style="margin:0;padding:0;background:{PAPER};-webkit-text-size-adjust:100%;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:{PAPER};">{preheader}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:{PAPER};">
<tr><td align="center" style="padding:32px 16px;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;background:#FFFFFF;border-radius:10px;overflow:hidden;border:1px solid {LINE};">
    <tr><td align="center" style="background:{NAVY};padding:28px 24px 26px;">
      <img src="{IMG}logo-branco.png" width="172" height="40" alt="Adami Captal" style="display:block;border:0;width:172px;height:auto;">
      <div style="font-family:{SANS};font-size:11px;letter-spacing:3px;text-transform:uppercase;color:{GOLD};padding-top:12px;">Hub Adami</div>
    </td></tr>
    <tr><td style="height:3px;line-height:3px;font-size:0;background:{GOLD};">&nbsp;</td></tr>
    <tr><td style="padding:36px 40px 8px;" class="miolo">
      <img src="{IMG}{icone}" width="56" height="56" alt="" style="display:block;border:0;width:56px;height:56px;">
      <h1 style="margin:20px 0 12px;font-family:{SERIF};font-weight:normal;font-size:26px;line-height:1.25;color:{INK};">{titulo}</h1>
      {corpo}
    </td></tr>
    <tr><td style="padding:20px 40px 8px;">
      <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
        <td align="center" bgcolor="{NAVY}" style="border-radius:6px;">
          <a href="{link}" target="_blank" style="display:inline-block;padding:14px 28px;font-family:{SANS};font-size:15px;font-weight:bold;color:#FFFFFF;text-decoration:none;border-radius:6px;">{botao}</a>
        </td>
      </tr></table>
    </td></tr>
    <tr><td style="padding:20px 40px 32px;font-family:{SANS};font-size:13px;line-height:1.6;color:{INK2};">
      {depois}
      <p style="margin:20px 0 0;padding-top:16px;border-top:1px solid {LINE};font-size:12px;color:{MUTED};">Se o botão não funcionar, copie e cole este endereço no navegador:<br>
      <a href="{link}" style="color:{NAVY};word-break:break-all;">{link}</a></p>
    </td></tr>
  </table>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">
    <tr><td align="center" style="padding:20px 24px 0;font-family:{SANS};font-size:12px;line-height:1.6;color:{MUTED};">
      <strong style="color:{INK2};">Hub Adami</strong> &middot; Adami Captal<br>
      <a href="https://adamicaptal.com.br/hub" style="color:{MUTED};">adamicaptal.com.br/hub</a><br>
      E-mail automático, não precisa responder.
    </td></tr>
  </table>
</td></tr>
</table>
</body>
</html>
"""

P = f"margin:0 0 14px;font-family:{SANS};font-size:15px;line-height:1.6;color:{INK2};"

modelos = {
  "redefinir-senha.html": email(
    "Redefinir sua senha",
    "Use o botão para criar uma nova senha no Hub Adami.",
    "icone-chave.png",
    "Redefinir sua senha",
    f'<p style="{P}">Recebemos um pedido para redefinir a senha do Hub Adami da conta <strong style="color:{INK};">{{{{ .Email }}}}</strong>.</p>'
    f'<p style="{P}">Clique no botão abaixo e escolha a nova senha.</p>',
    "Criar nova senha",
    '<p style="margin:0 0 10px;">O link vale por tempo limitado e só pode ser usado uma vez. Se expirar, peça outro na tela de login, em <strong>Esqueci minha senha</strong>.</p>'
    '<p style="margin:0;">Não foi você? Pode ignorar este e-mail. A sua senha continua a mesma.</p>',
    # O link só abre a tela; o código é gasto no clique em "Salvar nova senha".
    # Assim o robô de segurança do e-mail, que abre os links, não queima o código.
    link="{{ .SiteURL }}?token_hash={{ .TokenHash }}&type=recovery"),
  "boas-vindas.html": email(
    "Bem-vindo ao Hub Adami",
    "Seu acesso ao Hub Adami está liberado. Crie sua senha para entrar.",
    "icone-entrada.png",
    "Bem-vindo ao Hub Adami",
    f'<p style="{P}">{{{{SAUDACAO}}}}</p>'
    f'<p style="{P}">Seu acesso ao <strong style="color:{INK};">Hub Adami</strong> está liberado. É o ambiente interno da Adami Captal, com carteiras, CRM, Mesa RV e as ferramentas da casa em um só lugar.</p>'
    f'<p style="{P}">Para entrar pela primeira vez, clique no botão abaixo e escolha a sua senha. O seu login é <strong style="color:{INK};">{{{{EMAIL}}}}</strong>.</p>',
    "Criar minha senha",
    '<p style="margin:0 0 10px;">Depois disso, é só entrar em <strong>adamicaptal.com.br/hub</strong> com o seu e-mail e a senha que escolheu. Vale salvar nos favoritos.</p>'
    '<p style="margin:0;">Este link não expira. Se você já criou a senha, use <strong>Entrar</strong> na mesma tela.</p>',
    link="{{LINK}}"),
}
CORPO_SENHA = (f'<p style="{P}">Recebemos um pedido para redefinir a senha do Hub Adami da conta <strong style="color:{INK};">{{{{EMAIL}}}}</strong>.</p>'
    f'<p style="{P}">Clique no botão abaixo e escolha a nova senha.</p>')
DEPOIS_SENHA = ('<p style="margin:0 0 10px;">O link vale por tempo limitado e só pode ser usado uma vez. Se expirar, peça outro na tela de login, em <strong>Esqueci minha senha</strong>.</p>'
    '<p style="margin:0;">Não foi você? Pode ignorar este e-mail. A sua senha continua a mesma.</p>')
modelos["senha-funcao.html"] = email(
    "Redefinir sua senha",
    "Use o botão para criar uma nova senha no Hub Adami.",
    "icone-chave.png", "Redefinir sua senha", CORPO_SENHA, "Criar nova senha", DEPOIS_SENHA, link="{{LINK}}")
modelos["agenda-manha.html"] = email(
    "Sua agenda de hoje",
    "Suas tarefas de hoje e as atrasadas, da Agenda do CRM.",
    "icone-agenda.png",
    "{{SAUDACAO}}",
    "{{CONTEUDO}}",
    "Abrir a Agenda",
    '<p style="margin:0;">Este resumo sai nos dias úteis, por volta das 7h. Para tirar uma tarefa daqui, desmarque "Incluir no e-mail da manhã" nela, na Agenda do CRM.</p>',
    link="{{LINK}}")

pasta = os.path.dirname(os.path.abspath(__file__))
for nome, html in modelos.items():
    open(os.path.join(pasta, nome), "w").write(html)
    print(nome, len(html.encode()), "bytes")

TEXTO_BOAS_VINDAS = """{{SAUDACAO}}

Seu acesso ao Hub Adami está liberado. É o ambiente interno da Adami Captal, com carteiras, CRM, Mesa RV e as ferramentas da casa em um só lugar.

Para entrar pela primeira vez, abra o link abaixo e escolha a sua senha. O seu login é {{EMAIL}}.

{{LINK}}

Depois disso, é só entrar em adamicaptal.com.br/hub com o seu e-mail e a senha que escolheu. Este link não expira.

Hub Adami · Adami Captal
E-mail automático, não precisa responder.
"""

TEXTO_SENHA = """Recebemos um pedido para redefinir a senha do Hub Adami da conta {{EMAIL}}.

Abra o link abaixo e escolha a nova senha:

{{LINK}}

O link vale por tempo limitado e só pode ser usado uma vez. Se expirar, peça outro na tela de login, em Esqueci minha senha.
Não foi você? Pode ignorar este e-mail. A sua senha continua a mesma.

Hub Adami · Adami Captal
E-mail automático, não precisa responder.
"""

TEXTO_AGENDA = """{{SAUDACAO}}

{{CONTEUDO}}

Abrir a Agenda: {{LINK}}

Este resumo sai nos dias úteis, por volta das 7h.
Hub Adami · Adami Captal
"""

# Grava cada modelo dentro da sua função do Supabase, entre os marcadores.
raiz = os.path.join(pasta, "..")
for nome_funcao, html, texto in [
    ("enviar-convite", modelos["boas-vindas.html"], TEXTO_BOAS_VINDAS),
    ("enviar-senha", modelos["senha-funcao.html"], TEXTO_SENHA),
    ("agenda-manha", modelos["agenda-manha.html"], TEXTO_AGENDA),
]:
    funcao = os.path.join(raiz, "supabase", "functions", nome_funcao, "index.ts")
    ts = open(funcao).read()
    bloco = ("// <modelo> gerado por emails/_base.py\n"
             "const MODELO = " + json.dumps(html, ensure_ascii=False) + ";\n"
             "const MODELO_TEXTO = " + json.dumps(texto, ensure_ascii=False) + ";\n"
             "// </modelo>")
    assert ts.count("// <modelo>") == 1, nome_funcao
    ts2 = re.sub(r"// <modelo>.*?// </modelo>", lambda m: bloco, ts, flags=re.S)
    open(funcao, "w").write(ts2)
    print("modelo gravado em", os.path.relpath(funcao, raiz))
