<?php

  ini_set('display_errors', 1);
  ini_set('display_startup_errors', 1);
  error_reporting(E_ALL);
  $php_mail_exists = false;

  if (function_exists( 'mail' )) {echo 'php function mail() is available<br />'; $php_mail_exists = true;} else {echo 'php function mail() has been disabled<br />'; $php_mail_exists = false;} 
  
  include('./config/config.inc.php');
  
  function sendPrestaMail() {
      if (Mail::Send(
        (int)(Configuration::get('PS_LANG_DEFAULT')),
        'contact', 
        'Test Mail Send', 
        array(
          '{email}' => Configuration::get('PS_SHOP_EMAIL'), 
          '{order_name}' => '', 
          '{attached_file}' => '', 
          '{message}' => 'test mail with contact template'), 
          Configuration::get('PS_SHOP_EMAIL').'.', 
          NULL, 
          NULL, 
          NULL
      )) 
      return true; 
      
      else 
      
      return false; 
  }
  
  function sendPhpMail() {
      $msg = "test php mail without template";

      if (mail(Configuration::get('PS_SHOP_EMAIL'),"Test PHP Mail Send",$msg)) 
      return true;
      
      else
      
      return false;
  }
  
  if (sendPrestaMail() === true) {echo 'prestashop mail is OK and send to '.Configuration::get('PS_SHOP_EMAIL').'<br />';} else {print_r(error_get_last());}

  if ($php_mail_exists === true && sendPhpMail() === true) {echo 'PHP mail is OK and send to '.Configuration::get('PS_SHOP_EMAIL').'<br />';} else {print_r(error_get_last());}
  
  echo 'shop mail: '.Configuration::get('PS_SHOP_EMAIL'); 
    
