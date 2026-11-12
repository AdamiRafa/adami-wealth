<?php
// Teste temporário (12/11/2026): a senha (Authorization) chega ao PHP nesta hospedagem?
// Responde só sim/não. Nunca mostra a senha. Apagar depois do diagnóstico.
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
$h = function_exists('getallheaders') ? array_change_key_case(getallheaders(), CASE_LOWER) : array();
$a = isset($h['authorization']) ? $h['authorization'] : '';
echo json_encode(array(
  'cabecalho_authorization' => $a !== '',
  'esquema' => $a !== '' ? strtok($a, ' ') : null,
  'HTTP_AUTHORIZATION' => !empty($_SERVER['HTTP_AUTHORIZATION']),
  'REDIRECT_HTTP_AUTHORIZATION' => !empty($_SERVER['REDIRECT_HTTP_AUTHORIZATION']),
  'PHP_AUTH_USER' => isset($_SERVER['PHP_AUTH_USER']),
  'servidor' => isset($_SERVER['SERVER_SOFTWARE']) ? $_SERVER['SERVER_SOFTWARE'] : null,
));
