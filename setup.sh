#!/bin/bash
set -e

# Script to set up a development environment for Karpenter
# https://github.com/kubernetes-sigs/karpenter

echo "Setting up Karpenter development environment..."

# Apply PATH changes to current session immediately to avoid issues with tools not found
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
export GOPATH=$HOME/go

# Detect the Linux distribution
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VERSION=$VERSION_ID
else
    echo "Cannot detect OS distribution. This script supports Ubuntu, Debian, Amazon Linux, and CentOS/RHEL."
    exit 1
fi

echo "Detected OS: $OS $VERSION"

# Function to install dependencies on Ubuntu/Debian
install_on_debian() {
    echo "Installing dependencies for Ubuntu/Debian..."
    
    # Update package lists
    sudo apt-get update
    
    # Install basic tools
    sudo apt-get install -y git build-essential

    # Install Docker
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        sudo apt-get install -y apt-transport-https ca-certificates gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
        sudo usermod -aG docker $USER
        echo "Docker installed. You may need to log out and back in for group changes to take effect."
    else
        echo "Docker is already installed."
    fi
}

# Function to install dependencies on Amazon Linux
install_on_amazon_linux() {
    echo "Installing dependencies for Amazon Linux..."
    
    # Update package lists
    sudo yum update -y
    
    # Install basic tools
    sudo yum install -y git gcc make

    # Install Docker
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        sudo yum install -y docker
        sudo systemctl enable docker
        sudo systemctl start docker
        sudo usermod -aG docker $USER
        echo "Docker installed. You may need to log out and back in for group changes to take effect."
    else
        echo "Docker is already installed."
    fi
}

# Function to install dependencies on CentOS/RHEL
install_on_centos() {
    echo "Installing dependencies for CentOS/RHEL..."
    
    # Update package lists
    sudo yum update -y
    
    # Install basic tools
    sudo yum install -y git gcc make

    # Install Docker
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io
        sudo systemctl enable docker
        sudo systemctl start docker
        sudo usermod -aG docker $USER
        echo "Docker installed. You may need to log out and back in for group changes to take effect."
    else
        echo "Docker is already installed."
    fi
}

# Install OS-specific dependencies
case "$OS" in
    "Ubuntu"|"Debian GNU/Linux")
        install_on_debian
        ;;
    "Amazon Linux")
        install_on_amazon_linux
        ;;
    "CentOS Linux"|"Red Hat Enterprise Linux"|"Rocky Linux")
        install_on_centos
        ;;
    *)
        echo "Unsupported OS: $OS"
        exit 1
        ;;
esac

# Install Go
echo "Installing Go..."
# Use a stable Go version that exists
GO_VERSION="1.24.4"

# Check if go.mod exists and extract version if it does
if [ -f "go.mod" ]; then
    MOD_GO_VERSION=$(grep -E "^go [0-9]+\.[0-9]+(\.[0-9]+)?" go.mod | awk '{print $2}')
    if [ ! -z "$MOD_GO_VERSION" ]; then
        # Extract major and minor version only (e.g., 1.22 from 1.22.3)
        MAJOR_MINOR=$(echo $MOD_GO_VERSION | grep -oE "[0-9]+\.[0-9]+")
        # Find the latest patch version for this major.minor
        LATEST_VERSION=$(curl -s https://go.dev/dl/?mode=json | grep -o "\"version\": \"go${MAJOR_MINOR}[^\"]*\"" | sort -V | tail -1 | grep -o "[0-9]\+\.[0-9]\+\.[0-9]\+")
        if [ ! -z "$LATEST_VERSION" ]; then
            GO_VERSION=$LATEST_VERSION
            echo "Found Go version $MOD_GO_VERSION in go.mod, using latest patch version: $GO_VERSION"
        else
            echo "Could not find latest version for $MAJOR_MINOR, using default: $GO_VERSION"
        fi
    fi
fi

if ! command -v go &> /dev/null || [[ $(go version | awk '{print $3}' | sed 's/go//') < "$GO_VERSION" ]]; then
    wget https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
    rm go${GO_VERSION}.linux-amd64.tar.gz
    echo "Go ${GO_VERSION} installed."
else
    echo "Go is already installed: $(go version)"
fi

# Install kubectl
echo "Installing kubectl..."
if ! command -v kubectl &> /dev/null; then
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    echo "kubectl $(kubectl version --client -o json | jq -r '.clientVersion.gitVersion') installed."
else
    echo "kubectl is already installed: $(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')"
fi

# Install kind
echo "Installing kind..."
if ! command -v kind &> /dev/null; then
    KIND_VERSION="0.20.0"
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
    echo "kind v${KIND_VERSION} installed."
else
    echo "kind is already installed: $(kind --version)"
fi

# Install AWS CLI
echo "Installing AWS CLI..."
if ! command -v aws &> /dev/null; then
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
    echo "AWS CLI installed: $(aws --version)"
else
    echo "AWS CLI is already installed: $(aws --version)"
fi

# Install Helm
echo "Installing Helm..."
if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "Helm installed: $(helm version --short)"
else
    echo "Helm is already installed: $(helm version --short)"
fi

# Install eksctl (useful for EKS clusters)
echo "Installing eksctl..."
if ! command -v eksctl &> /dev/null; then
    ARCH=amd64
    PLATFORM=$(uname -s)_$ARCH
    curl -sLO "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
    tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz
    sudo mv /tmp/eksctl /usr/local/bin
    echo "eksctl installed: $(eksctl version)"
else
    echo "eksctl is already installed: $(eksctl version)"
fi

# Update PATH permanently
echo "Updating PATH in shell profile..."
SHELL_PROFILE=""
if [ -f "$HOME/.bashrc" ]; then
    SHELL_PROFILE="$HOME/.bashrc"
elif [ -f "$HOME/.bash_profile" ]; then
    SHELL_PROFILE="$HOME/.bash_profile"
elif [ -f "$HOME/.zshrc" ]; then
    SHELL_PROFILE="$HOME/.zshrc"
else
    echo "Could not find shell profile. Please manually add the following to your shell profile:"
    echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin'
    echo 'export GOPATH=$HOME/go'
fi

if [ -n "$SHELL_PROFILE" ]; then
    # Check if PATH already contains Go paths
    if ! grep -q "export PATH=.*\/usr\/local\/go\/bin" "$SHELL_PROFILE"; then
        echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> "$SHELL_PROFILE"
    fi
    
    # Check if GOPATH is already set
    if ! grep -q "export GOPATH=" "$SHELL_PROFILE"; then
        echo 'export GOPATH=$HOME/go' >> "$SHELL_PROFILE"
    fi
    
    echo "PATH and GOPATH have been updated in $SHELL_PROFILE"
fi

# Apply PATH changes to current session
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
export GOPATH=$HOME/go

# Install controller-gen
echo "Installing controller-gen..."
if ! command -v controller-gen &> /dev/null; then
    go install sigs.k8s.io/controller-tools/cmd/controller-gen@latest
    echo "controller-gen installed: $(controller-gen --version 2>&1 || echo 'installed')"
else
    echo "controller-gen is already installed"
fi

# Install eks-node-viewer
echo "Installing eks-node-viewer..."
if ! command -v eks-node-viewer &> /dev/null; then
    go install github.com/awslabs/eks-node-viewer/cmd/eks-node-viewer@latest
    echo "eks-node-viewer installed: $(eks-node-viewer --version 2>&1 || echo 'installed')"
else
    echo "eks-node-viewer is already installed"
fi

# Clone Karpenter repository
echo "Cloning Karpenter repository..."
if [ ! -d "$HOME/karpenter" ]; then
    git clone https://github.com/kubernetes-sigs/karpenter.git "$HOME/karpenter"
    echo "Karpenter repository cloned to $HOME/karpenter"
else
    echo "Karpenter repository already exists at $HOME/karpenter"
    echo "To update it, run: cd $HOME/karpenter && git pull"
fi

source $SHELL_PROFILE

echo ""
echo "======================================================================"
echo "Karpenter development environment setup complete!"
echo ""
echo "To verify all tools are installed correctly:"
echo "  go version"
echo "  controller-gen --version"
echo "  kubectl version --client"
echo "  kind version"
echo "  eks-node-viewer --version"
echo ""
echo "For more information, visit: https://github.com/kubernetes-sigs/karpenter"
echo "======================================================================"
