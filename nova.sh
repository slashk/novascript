#!/usr/bin/env bash

##### Variables to Change ####
SOURCE_BRANCH=lp:nova
TEST=0
USE_MYSQL=0
MYSQL_PASS=nova
USE_LDAP=0
LIBVIRT_TYPE=uml
USE_FLAT_NETWORK=0
FLAT_NETWORK=192.168.2.0 # Your network range
FLAT_NETWORK_PREFIX=24 # CIDR
FLAT_NETWORK_SIZE=16 # number of nodes
FLAT_NETWORK_BROADCAST=192.168.2.255 # broadcast address
###############

DIR=`pwd`
CMD=$1
DIRNAME=nova
NOVA_DIR=$DIR/$DIRNAME
NL=`echo -ne '\015'`

function screen_it {
    screen -S nova -X screen -t $1
    screen -S nova -p $1 -X stuff "$2$NL"
}

if [ -n "$2" ]; then
    SOURCE_BRANCH=$2
fi

if [ -n "$3" ]; then
    NOVA_DIR=$DIR/$3
fi

if [ ! -n "$HOST_IP" ]; then
    # NOTE(vish): This will just get the first ip in the list, so if you
    #             have more than one eth device set up, this will fail, and
    #             you should explicitly set HOST_IP in your environment
    HOST_IP=`ifconfig  | grep -m 1 'inet addr:'| cut -d: -f2 | awk '{print $1}'`
fi

if [ "$USE_MYSQL" == 1 ]; then
    SQL_CONN=mysql://root:$MYSQL_PASS@localhost/nova
else
    SQL_CONN=sqlite:///$NOVA_DIR/nova.sqlite
fi

if [ "$USE_LDAP" == 1 ]; then
    AUTH=ldapdriver.LdapDriver
else
    AUTH=dbdriver.DbDriver
fi

mkdir -p /etc/nova
cat >/etc/nova/nova-manage.conf << NOVA_CONF_EOF
--verbose
--nodaemon
--dhcpbridge_flagfile=/etc/nova/nova-manage.conf
--FAKE_subdomain=ec2
--cc_host=$HOST_IP
--routing_source_ip=$HOST_IP
--sql_connection=$SQL_CONN
--auth_driver=nova.auth.$AUTH
--libvirt_type=$LIBVIRT_TYPE
NOVA_CONF_EOF

if [ "$USE_FLAT_NETWORK" == 1 ]; then
cat >>/etc/nova/nova-manage.conf << NOVA_NET_CONF_EOF
--network_manager=nova.network.manager.FlatManager
--fixed_range=${FLAT_NETWORK}/${FLAT_NETWORK_PREFIX}
--network_size=${FLAT_NETWORK_SIZE}
--flat_network=true
--flat_network_bridge=br0
--flat_network_broadcast=${FLAT_NETWORK_BROADCAST}
NOVA_NET_CONF_EOF
fi

if [ "$CMD" == "branch" ]; then
    sudo apt-get install -y bzr
    rm -rf $NOVA_DIR
    bzr branch $SOURCE_BRANCH $NOVA_DIR
    cd $NOVA_DIR
    mkdir -p $NOVA_DIR/instances
    mkdir -p $NOVA_DIR/networks
fi

# You should only have to run this once
if [ "$CMD" == "install" ]; then
    sudo apt-get install -y python-software-properties
    sudo add-apt-repository ppa:nova-core/ppa
    sudo apt-get update
    sudo apt-get install -y dnsmasq open-iscsi kpartx kvm gawk iptables ebtables
    sudo apt-get install -y user-mode-linux kvm libvirt-bin
    sudo apt-get install -y screen iscsitarget euca2ools vlan curl rabbitmq-server
	sudo apt-get install -y wget
    sudo modprobe kvm
    sudo /etc/init.d/libvirt-bin restart
    sudo apt-get install -y python-twisted python-sqlalchemy python-mox python-greenlet python-carrot
    sudo apt-get install -y python-daemon python-eventlet python-gflags python-tornado python-ipy
    sudo apt-get install -y python-libvirt python-libxml2 python-routes
    if [ "$USE_MYSQL" == 1 ]; then
        cat <<MYSQL_PRESEED | debconf-set-selections
mysql-server-5.1 mysql-server/root_password password $MYSQL_PASS
mysql-server-5.1 mysql-server/root_password_again password $MYSQL_PASS
mysql-server-5.1 mysql-server/start_on_boot boolean true
MYSQL_PRESEED
        apt-get install -y mysql-server python-mysqldb
    fi
    wget http://c2477062.cdn.cloudfiles.rackspacecloud.com/images.tgz
    tar -C $DIR -zxf images.tgz
fi

if [ "$CMD" == "run" ]; then
    killall dnsmasq
    screen -d -m -S nova -t nova
    sleep 1
    if [ "$USE_MYSQL" == 1 ]; then
        mysql -p$MYSQL_PASS -e 'DROP DATABASE nova;'
        mysql -p$MYSQL_PASS -e 'CREATE DATABASE nova;'
    else
        rm $NOVA_DIR/nova.sqlite
    fi
    if [ "$USE_LDAP" == 1 ]; then
        sudo $NOVA_DIR/nova/auth/slap.sh
    fi
    rm -rf $NOVA_DIR/instances
    mkdir -p $NOVA_DIR/instances
    rm -rf $NOVA_DIR/networks
    mkdir -p $NOVA_DIR/networks
    $NOVA_DIR/tools/clean-vlans
    if [ ! -d "$NOVA_DIR/images" ]; then
        ln -s $DIR/images $NOVA_DIR/images
    fi

    if [ "$TEST" == 1 ]; then
        cd $NOVA_DIR
        python $NOVA_DIR/run_tests.py
        cd $DIR
    fi

    # create an admin user called 'admin'
    $NOVA_DIR/bin/nova-manage user admin admin admin admin
    # create a project called 'admin' with project manager of 'admin'
    $NOVA_DIR/bin/nova-manage project create admin admin
    # export environment variables for project 'admin' and user 'admin'
    $NOVA_DIR/bin/nova-manage project environment admin admin $NOVA_DIR/novarc
    # create 3 small networks
	if [ "$USE_FLAT_NETWORK" == 1 ]; then
		$NOVA_DIR/bin/nova-manage network create
	else
    	$NOVA_DIR/bin/nova-manage network create 10.0.0.0/8 3 16
	fi


    # nova api crashes if we start it with a regular screen command,
    # so send the start command by forcing text into the window.
    screen_it api "$NOVA_DIR/bin/nova-api --flagfile=/etc/nova/nova-manage.conf"
    screen_it objectstore "$NOVA_DIR/bin/nova-objectstore --flagfile=/etc/nova/nova-manage.conf"
    screen_it compute "$NOVA_DIR/bin/nova-compute --flagfile=/etc/nova/nova-manage.conf"
    screen_it network "$NOVA_DIR/bin/nova-network --flagfile=/etc/nova/nova-manage.conf"
    screen_it scheduler "$NOVA_DIR/bin/nova-scheduler --flagfile=/etc/nova/nova-manage.conf"
    screen_it volume "$NOVA_DIR/bin/nova-volume --flagfile=/etc/nova/nova-manage.conf"
    screen_it test ". $NOVA_DIR/novarc"
    screen -x
fi

if [ "$CMD" == "run" ] || [ "$CMD" == "terminate" ]; then
    # shutdown instances
    . $NOVA_DIR/novarc; euca-describe-instances | grep i- | cut -f2 | xargs euca-terminate-instances
    sleep 2
fi

if [ "$CMD" == "run" ] || [ "$CMD" == "clean" ]; then
    screen -S nova -X quit
    rm *.pid*
    $NOVA_DIR/tools/setup_iptables.sh clear
fi

if [ "$CMD" == "scrub" ]; then
    $NOVA_DIR/tools/clean-vlans
    if [ "$LIBVIRT_TYPE" == "uml" ]; then
        virsh -c uml:///system list | grep i- | awk '{print \$1}' | xargs -n1 virsh -c uml:///system destroy
    else
        virsh list | grep i- | awk '{print \$1}' | xargs -n1 virsh destroy
    fi
    vblade-persist ls | grep vol- | awk '{print \$1\" \"\$2}' | xargs -n2 vblade-persist destroy
fi
