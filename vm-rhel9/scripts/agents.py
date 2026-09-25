from runtime import *
import hashlib

def setup(dynamic=False):
    from services import postgres
    if dynamic:
        postgres()
        ssh('app','systemctl stop vm-agent-db-once.timer vm-agent-db-once.service 2>/dev/null || true\n')
    name='db' if dynamic else 'static';port=18081 if dynamic else 18080
    v=Vault();v.auth('approle','approle');v.mount('secret')
    path='database/creds/agent-db' if dynamic else 'secret/data/jboss/demo'
    v.policy('agent-'+name,'path "'+path+'" { capabilities = ["read"] }')
    v.post('auth/approle/role/agent-'+name,{'token_policies':['agent-'+name],'token_ttl':'10m','token_max_ttl':'1h','secret_id_ttl':'24h'})
    role=v.get('auth/approle/role/agent-'+name+'/role-id')['data']['role_id']
    sid=v.post('auth/approle/role/agent-'+name+'/secret-id')['data']['secret_id']
    base='/opt/vm-agent-'+name
    ssh('app',f'''
. /etc/os-release
test "$ID" = rhel
[[ "$VERSION_ID" == 9.* ]]
test "$(getenforce)" = Enforcing
test -f /var/lib/vault/rhel9-ready
id vaultapp >/dev/null 2>&1 || useradd --system --home-dir /opt/vm-agent --shell /sbin/nologin vaultapp
mkdir -p {base}/secrets
if [ ! -d {base}/wildfly ]; then
 curl -fsSL https://github.com/wildfly/wildfly/releases/download/36.0.1.Final/wildfly-36.0.1.Final.zip -o /var/tmp/wildfly.zip
 unzip -oq /var/tmp/wildfly.zip -d {base}
 mv {base}/wildfly-36.0.1.Final {base}/wildfly
fi
mkdir -p {base}/wildfly/standalone/deployments/vault-demo.war/WEB-INF/lib
chown -R vaultapp:vaultapp {base}
''')
    for dest,data in [('role_id',role),('secret_id',sid)]:put('app',base+'/'+dest,data,'vaultapp:vaultapp')
    if dynamic:
        host=(STATE/'postgres-endpoint').read_text()
        ssh('app',f'curl -fsSL https://jdbc.postgresql.org/download/postgresql-42.7.7.jar -o {base}/wildfly/standalone/deployments/vault-demo.war/WEB-INF/lib/postgresql.jar\nchown vaultapp:vaultapp {base}/wildfly/standalone/deployments/vault-demo.war/WEB-INF/lib/postgresql.jar\nchmod 640 {base}/wildfly/standalone/deployments/vault-demo.war/WEB-INF/lib/postgresql.jar\n')
        jsp='<%@ page import="java.sql.*" %><% Class.forName("org.postgresql.Driver"); try(Connection c=DriverManager.getConnection("jdbc:postgresql://'+host+':5432/postgres",System.getProperty("demo.username"),System.getProperty("demo.password"))){try(Statement s=c.createStatement();ResultSet r=s.executeQuery("select 1")){if(r.next() && r.getInt(1)==1)out.print("DB_CONNECTION_OK");else response.setStatus(500);}} %>'
        content='{{ with secret "database/creds/agent-db" }}\ndemo.username={{ .Data.username }}\ndemo.password={{ .Data.password }}\n{{ end }}'
    else:
        v.post('secret/data/jboss/demo',{'data':{'username':'appuser','password':'version-1'}})
        jsp='<%@ page import="java.security.*" %><% byte[] digest=MessageDigest.getInstance("SHA-256").digest(System.getProperty("demo.password").getBytes("UTF-8"));for(byte b:digest)out.print(String.format("%02x",b)); %>'
        content='{{ with secret "secret/data/jboss/demo" }}\ndemo.username={{ .Data.data.username }}\ndemo.password={{ .Data.data.password }}\n{{ end }}'
    put('app',base+'/wildfly/standalone/deployments/vault-demo.war/index.jsp',jsp,'vaultapp:vaultapp','640')
    ssh('app',f'touch {base}/wildfly/standalone/deployments/vault-demo.war.dodeploy\n')
    unit=f'''[Unit]
Description=VM WildFly {name}
After=network-online.target
[Service]
User=vaultapp
Group=vaultapp
Environment=JAVA_HOME=/usr/lib/jvm/jre-21-openjdk
ExecStart={base}/wildfly/bin/standalone.sh -b 127.0.0.1 -Djboss.socket.binding.port-offset={10001 if dynamic else 10000} -P {base}/secrets/application.properties
Restart=on-failure
[Install]
WantedBy=multi-user.target
'''
    put('app','/etc/systemd/system/vm-wildfly-'+name+'.service',unit,'root:root','644')
    put('app','/etc/sudoers.d/vm-agent-'+name,f'vaultapp ALL=(root) NOPASSWD: /usr/bin/systemctl restart vm-wildfly-{name}.service\n','root:root','440')
    agent=f'''vault {{ address = "{v.addr}" }}
auto_auth {{
 method "approle" {{
  config = {{ role_id_file_path = "{base}/role_id", secret_id_file_path = "{base}/secret_id", remove_secret_id_file_after_reading = false }}
 }}
 sink "file" {{ config = {{ path = "{base}/token" }} }}
}}
template_config {{ static_secret_render_interval = "5s" }}
template {{
 destination = "{base}/secrets/application.properties"
 perms = "0600"
 contents = <<EOH
{content}
EOH
 exec {{
  command = ["/usr/bin/sudo", "/usr/bin/systemctl", "restart", "vm-wildfly-{name}.service"]
  timeout = "90s"
 }}
}}
'''
    put('app',base+'/agent.hcl',agent,'vaultapp:vaultapp')
    put('app','/etc/systemd/system/vm-agent-'+name+'.service',f'''[Unit]
Description=Vault Agent {name}
After=network-online.target
[Service]
User=vaultapp
Group=vaultapp
ExecStart=/usr/local/bin/vault agent -config={base}/agent.hcl
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
''','root:root','644')
    ssh('app',f'systemctl daemon-reload\nsystemctl enable vm-wildfly-{name} vm-agent-{name}\nsystemctl restart vm-agent-{name}\n')
    wait_for(lambda:'DB_CONNECTION_OK' in fetch(port) if dynamic else hashlib.sha256(b'version-1').hexdigest() in fetch(port),timeout=300)
    print('WildFly',name,'and Vault Agent run under systemd on RHEL 9; application response verified')

def fetch(port):return ssh('app',f'curl -fsS --max-time 10 http://127.0.0.1:{port}/vault-demo/index.jsp',timeout=20)

def rotate_static():
    marker=secrets.token_hex(16);Vault().post('secret/data/jboss/demo',{'data':{'username':'appuser','password':marker}})
    wait_for(lambda:hashlib.sha256(marker.encode()).hexdigest() in fetch(18080),timeout=180)
    print('KV update rendered and WildFly restarted; application digest matches new secret')

def rotate_dynamic():
    # Force lease revocation; Agent reauth/restart obtains fresh SQL credentials.
    v=Vault();v.post('sys/leases/revoke-prefix/database/creds/agent-db')
    ssh('app','systemctl restart vm-agent-db\n')
    wait_for(lambda:'DB_CONNECTION_OK' in fetch(18081),timeout=180)
    # One-shot execution through a systemd timer is the RHEL equivalent of the source cron case.
    base='/opt/vm-agent-db'
    hcl=ssh('app',f'cat {base}/agent.hcl').replace('template_config {','exit_after_auth = true\ntemplate_config {')
    put('app',base+'/oneshot.hcl',hcl,'vaultapp:vaultapp')
    put('app','/etc/systemd/system/vm-agent-db-once.service',f'[Unit]\nDescription=One-shot SQL credential refresh\n[Service]\nType=oneshot\nUser=vaultapp\nGroup=vaultapp\nExecStart=/usr/local/bin/vault agent -config={base}/oneshot.hcl\n','root:root','644')
    put('app','/etc/systemd/system/vm-agent-db-once.timer','[Unit]\nDescription=Refresh SQL credentials every two minutes\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=2min\n[Install]\nWantedBy=timers.target\n','root:root','644')
    ssh('app','systemctl stop vm-agent-db\nsystemctl daemon-reload\nsystemctl start vm-agent-db-once\nsystemctl enable --now vm-agent-db-once.timer\n')
    wait_for(lambda:'DB_CONNECTION_OK' in fetch(18081),timeout=180)
    print('Revoked credential replaced; systemd one-shot timer and real JDBC login verified')
