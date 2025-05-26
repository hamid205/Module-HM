
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient


key_vault_name = "keyVault-hh"
key_vault_url = f"https://{key_vault_name}.vault.azure.net/"


credential = DefaultAzureCredential()
client = SecretClient(vault_url=key_vault_url, credential=credential)

retrieved_secret = client.get_secret("hamidd")
print(f"Passwort aus Key Vault: {retrieved_secret.value}")
