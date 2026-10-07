shader_type canvas_item;
// Authored, finite cumulus clusters for departure; a horizontal volume for arrival.
// Both are integrated along the camera ray. No billboard, coverage fade or reseed.
uniform sampler3D density_noise : filter_linear, repeat_enable;
uniform vec3 eye=vec3(0,150,0);
uniform vec3 camera_right=vec3(1,0,0);
uniform vec3 camera_up=vec3(0,0,-1);
uniform vec3 camera_forward=vec3(0,-1,0);
uniform bool orthographic=false;
uniform float view_extent=.48;
uniform float aspect=1.77778;
uniform float cover : hint_range(0.0,1.0)=0.0;
uniform float drift=0.0;
uniform bool deck_mode=false;
uniform vec3 cloud_centers[5];
uniform vec3 cloud_radii[5];
uniform bool roof_enabled=false;
uniform vec3 roof_center=vec3(0,100,0);
float deck_density(vec3 p){
	vec3 wind=vec3(drift*.00032,0,drift*.00017);
	float spread=texture(density_noise,vec3(p.x*.0018,.32,p.z*.0018)+wind).r;
	float base=78.0+(spread-.5)*9.0;
	float h=(p.y-base)/(22.0+spread*30.0);
	float envelope=smoothstep(0.0,.13,h)*(1.0-smoothstep(.50,1.0,h));
	if(envelope<.001)return 0.0;
	float large=texture(density_noise,p*vec3(.0048,.008,.0048)+wind).r;
	float detail=texture(density_noise,p*.029+wind*1.5).r;
	float shape=large*.78+detail*.22+spread*.28-.62;
	return max(shape,0.0)*envelope*3.8;
}
float cluster_density(vec3 p){
	float result=0.0;
	for(int k=0;k<5;k++){
		vec3 q=(p-cloud_centers[k])/cloud_radii[k];
		if(dot(q,q)>3.3)continue;
		float angle=float(k)*.73;
		q.xz=mat2(vec2(cos(angle),sin(angle)),vec2(-sin(angle),cos(angle)))*q.xz;
		// A broad base and unequal lobes, not equally sized spheres tiled together.
		float shape=length(q/vec3(1.12,.49,.76));
		shape=min(shape,length((q-vec3(-.47,.14,.03))/vec3(.62,.69,.68)));
		shape=min(shape,length((q-vec3(.03,.36,-.06))/vec3(.61,.91,.62)));
		shape=min(shape,length((q-vec3(.56,.13,.02))/vec3(.57,.65,.62)));
		shape=min(shape,length((q-vec3(-.21,.31,.42))/vec3(.39,.53,.37)));
		shape=min(shape,length((q-vec3(.31,.28,.44))/vec3(.35,.41,.38)));
		vec3 seed=vec3(float(k)*.163,.17,float(k)*.071);
		float broad=texture(density_noise,q*.29+seed).r;
		float detail=texture(density_noise,q*.89+seed).r;
		float edge=shape+(broad-.48)*.88+(detail-.48)*.23;
		float lobes=1.0-smoothstep(.85,1.04,edge);
		float base=smoothstep(-.55,-.35,q.y);
		result+=lobes*base*.34;
	}
	return result;
}
float roof_density(vec3 p){
	vec3 q=(p-roof_center)/vec3(72.0,25.0,72.0);
	float edge=length(q);
	if(edge>1.1)return 0.0;
	float detail=texture(density_noise,p*.018).r;
	return (1.0-smoothstep(.64,1.04,edge+(detail-.5)*.24))*.38;
}
float density(vec3 p){
	if(deck_mode)return deck_density(p);
	return cluster_density(p)+(roof_enabled?roof_density(p):0.0);
}

void fragment(){
	vec2 plane=(UV*2.0-1.0)*vec2(aspect,-1.0)*view_extent;
	vec3 ro=eye;
	vec3 rd=camera_forward;
	if(orthographic){ro+=camera_right*plane.x+camera_up*plane.y;}
	else{rd=normalize(rd+camera_right*plane.x+camera_up*plane.y);}
	float trans=1.0;vec3 sum=vec3(0);
	float begin=1500.0;
	float finish=0.0;
	if(deck_mode && abs(rd.y)>.015){
		float a=(72.0-ro.y)/rd.y;
		float b=(134.0-ro.y)/rd.y;
		begin=max(0.0,min(a,b));
		finish=min(max(a,b),1500.0);
	}else if(!deck_mode){
		// Only march rays that hit the finite clouds. Empty sky costs no density samples.
		for(int k=0;k<5;k++){
			vec3 radii=cloud_radii[k]*1.65;
			vec3 o=(ro-cloud_centers[k])/radii;
			vec3 d=rd/radii;
			float a=dot(d,d), b=dot(o,d), c=dot(o,o)-1.0;
			float h=b*b-a*c;
			if(h>0.0){
				float near_hit=(-b-sqrt(h))/a;
				float far_hit=(-b+sqrt(h))/a;
				if(far_hit>0.0){begin=min(begin,max(0.0,near_hit));finish=max(finish,far_hit);}
			}
		}
		if(roof_enabled){
			vec3 radii=vec3(79.2,27.5,79.2);
			vec3 o=(ro-roof_center)/radii;
			vec3 d=rd/radii;
			float a=dot(d,d),b=dot(o,d),c=dot(o,o)-1.0;
			float h=b*b-a*c;
			if(h>0.0){
				float near_hit=(-b-sqrt(h))/a;
				float far_hit=(-b+sqrt(h))/a;
				if(far_hit>0.0){begin=min(begin,max(0.0,near_hit));finish=max(finish,far_hit);}
			}
		}
	}
		if(finish>begin){
			float stride=(finish-begin)/72.0;
			vec3 sun=normalize(vec3(-.55,.83,-.18));
			for(int i=0;i<72;i++){
				vec3 p=ro+rd*(begin+(float(i)+.5)*stride);
				float d=density(p);
				if(d>.002){
					float shade=density(p+sun*4.0)*1.1+density(p+sun*11.0)*2.4+density(p+sun*23.0)*3.4;
					float light=exp(-shade*.72);
					light=mix(light,floor(light*6.0)/6.0,.18);
					vec3 color=mix(vec3(.72,.81,.875),vec3(1.0,.993,.974),light);
					float opacity=1.0-exp(-d*stride*.90);
					sum+=color*opacity*trans;
					trans*=1.0-opacity;
					if(trans<.006)break;
				}
			}
		}
	float alpha=1.0-trans;
	vec3 color=sum/max(alpha,.001);
	// Only the brief scene swap uses a full interior mist; all revealed cloud
	// shapes and openings come from the volume, including the downward flythrough.
	color=mix(color,vec3(.92,.95,.965),cover);
	alpha=mix(alpha,1.0,cover);
	COLOR=vec4(color,alpha);
}
