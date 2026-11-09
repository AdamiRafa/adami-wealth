<?php
/*
 * Repasse dos avisos do BTG (09/11/2026).
 *
 * O BTG recusou cadastrar o endereço do Supabase (ghxjqmjtmbqzvogwzylo.supabase.co) como webhook:
 * o domínio precisa estar registrado em nome do parceiro e não pode ser de "sistema aberto".
 * Por isso o BTG chama o domínio da Adami:
 *
 *     https://adamicaptal.com.br/hub/webhook/btg/<serviço>
 *
 * e este arquivo passa o aviso, sem mexer em nada, para a função btg-webhook do Supabase, que é
 * quem confere a senha (BTG_WEBHOOK_KEY), baixa o arquivo e grava. A resposta dela volta igual
 * para o BTG. Aqui não há senha nem dado guardado.
 *
 * Proteções: só POST; serviço só com letras, números e hífen; aviso de até 1 MB (é um JSON com
 * um link); destino fixo (não dá para usar este arquivo para chamar outro endereço).
 */
const DESTINO = 'https://ghxjqmjtmbqzvogwzylo.supabase.co/functions/v1/btg-webhook/';
const LIMITE = 1048576;

function sair($status, $corpo) {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo $corpo;
    exit;
}

$servico = isset($_GET['servico']) ? $_GET['servico'] : '';
if (!preg_match('/^[a-z0-9][a-z0-9-]{2,79}$/', $servico)) sair(404, '{"erro":"serviço desconhecido"}');
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { header('Allow: POST'); sair(405, '{"erro":"use POST"}'); }

$corpo = file_get_contents('php://input', false, null, 0, LIMITE + 1);
if ($corpo === false) $corpo = '';
if (strlen($corpo) > LIMITE) sair(413, '{"erro":"aviso grande demais"}');

/* Cabeçalhos do BTG (a senha vai num deles): passam todos, menos os de transporte. */
$fora = array('host', 'content-length', 'connection', 'keep-alive', 'transfer-encoding', 'accept-encoding',
              'cookie', 'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto', 'x-real-ip', 'expect');
$cab = array();
if (function_exists('getallheaders')) {
    foreach (getallheaders() as $k => $v) {
        if (!in_array(strtolower($k), $fora, true)) $cab[] = $k . ': ' . $v;
    }
} else {
    foreach ($_SERVER as $k => $v) {
        if (strpos($k, 'HTTP_') !== 0) continue;
        $nome = str_replace(' ', '-', ucwords(strtolower(str_replace('_', ' ', substr($k, 5)))));
        if (!in_array(strtolower($nome), $fora, true)) $cab[] = $nome . ': ' . $v;
    }
    if (!empty($_SERVER['CONTENT_TYPE'])) $cab[] = 'Content-Type: ' . $_SERVER['CONTENT_TYPE'];
}
$cab[] = 'X-Repasse: adamicaptal-hub';

$ch = curl_init(DESTINO . $servico);
curl_setopt_array($ch, array(
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => $corpo,
    CURLOPT_HTTPHEADER => $cab,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_FOLLOWLOCATION => false,
    CURLOPT_CONNECTTIMEOUT => 10,
    CURLOPT_TIMEOUT => 55,
    CURLOPT_SSL_VERIFYPEER => true,
    CURLOPT_SSL_VERIFYHOST => 2,
));
$resp = curl_exec($ch);
$status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
$erro = curl_error($ch);
curl_close($ch);

if ($resp === false || $status === 0) {
    error_log('repasse BTG falhou (' . $servico . '): ' . $erro);
    sair(502, '{"erro":"o Hub não conseguiu falar com o Supabase agora"}');
}
sair($status, $resp);
